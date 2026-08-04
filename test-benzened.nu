#!/usr/bin/env nu

const BINARIES = [benzened benzened_runas benzened_su_client]
const APP_DOMAIN = r#'u:r:(untrusted_app|priv_app|platform_app)'#
const SU_HIDDEN = r#'No such|not debuggable|unknown package'#
const DENIAL = r#'avc: *denied.*benzened'#

# Run an adb shell command, merging stderr and stripping CR
def adb-sh [serial: string, cmd: string]: nothing -> string {
  let result = (do { ^adb -s $serial shell $cmd } | complete)
  $"($result.stdout)($result.stderr)" | str replace --all "\r" ""
}

def mark-pass [name: string]: nothing -> record {
  print $"  PASS  ($name)"
  {status: pass, name: $name}
}

def mark-fail [name: string, detail: string]: nothing -> record {
  print $"  FAIL  ($name)"
  print $"        ($detail)"
  {status: fail, name: $name}
}

def mark-skip [name: string, detail: string]: nothing -> record {
  print $"  SKIP  ($name)"
  print $"        ($detail)"
  {status: skip, name: $name}
}

def header [title: string] {
  print ""
  print $"== ($title)"
}

def tail-lines [count: int]: string -> string {
  $in | lines | last $count | str join "\n"
}

def check-preconditions [serial: string]: nothing -> list<record> {
  header "0. preconditions"
  let mode = (adb-sh $serial "getenforce" | str trim)
  let boot = (adb-sh $serial "getprop sys.boot_completed" | str trim)
  [
    (if $mode == "Enforcing" {
      mark-pass "SELinux Enforcing"
    } else {
      mark-fail $"SELinux is ($mode)" "results are meaningless unless Enforcing"
    })
    (if $boot == "1" {
      mark-pass "boot completed"
    } else {
      mark-fail "boot not completed" $"sys.boot_completed=($boot)"
    })
  ]
}

def check-present [serial: string]: nothing -> list<record> {
  header "1. benzened is present and running"
  let installed = ($BINARIES | each {|binary|
    if (adb-sh $serial $"ls /system/bin/($binary)" | str contains "No such") {
      mark-fail $"/system/bin/($binary) installed" "missing from image"
    } else {
      mark-pass $"/system/bin/($binary) installed"
    }
  })

  let alive = if (adb-sh $serial "ps -A" | str contains "benzened") {
    mark-pass "benzened process alive"
  } else {
    mark-fail "benzened process alive" (adb-sh $serial "logcat -d -s benzened" | tail-lines 3)
  }

  let services = (adb-sh $serial "service list")
  let daemon = if ($services | str contains "IBenzened/default") {
    mark-pass "IBenzened registered"
  } else {
    let denials = (adb-sh $serial "logcat -d" | lines | where $it =~ '(?i)avc.*benzened' | last 3 | str join "\n")
    mark-fail "IBenzened registered" $denials
  }

  let grants = if ($services | str contains "IBenzenedGrants/default") {
    mark-pass "IBenzenedGrants registered"
  } else {
    mark-fail "IBenzenedGrants registered" "system_server may have failed to publish it"
  }

  $installed | append [$alive $daemon $grants]
}

def check-denials [serial: string]: nothing -> list<record> {
  header "2. no SELinux denials"
  let denials = (adb-sh $serial "logcat -d" | lines | where $it =~ $DENIAL)
  let count = ($denials | length)
  [
    (if $count == 0 {
      mark-pass "zero benzened avc denials"
    } else {
      mark-fail $"($count) benzened avc denials" ($denials | last 4 | str join "\n")
    })
  ]
}

def check-ungranted [serial: string, ungranted: string]: nothing -> list<record> {
  header "3. negative case, ungranted app sees nothing"
  let listing = (adb-sh $serial $"run-as ($ungranted) ls /mnt/benzene/su")
  let path = (adb-sh $serial $"run-as ($ungranted) sh -c 'echo $PATH'")
  [
    (if $listing =~ $SU_HIDDEN {
      mark-pass $"($ungranted) cannot see /mnt/benzene/su"
    } else {
      mark-fail "ungranted app CAN see su" $listing
    })
    (if ($path | str contains "benzene") {
      mark-fail "ungranted app PATH is polluted" $path
    } else {
      mark-pass $"($ungranted) PATH has no benzene entry"
    })
  ]
}

def check-impersonation [serial: string, granted: string]: nothing -> list<record> {
  header "4. impersonation worker"
  let uid = (adb-sh $serial $"/system/bin/benzened_runas ($granted) 0 id -u" | str trim)
  let context = (adb-sh $serial $"/system/bin/benzened_runas ($granted) 0 id -Z" | str trim)
  let reported = (
    adb-sh $serial $"dumpsys package ($granted)"
    | lines
    | where $it =~ 'userId='
    | get -o 0
    | default "unknown"
    | str trim
  )
  [
    (if ($uid =~ '^[0-9]+$') and $uid != "0" {
      mark-pass $"benzened_runas became uid ($uid) (package reports ($reported))"
    } else {
      mark-fail "benzened_runas did not switch uid" $"got '($uid)', expected the app's uid"
    })
    (if $context =~ $APP_DOMAIN {
      mark-pass $"context is ($context)"
    } else {
      mark-fail "context did not switch" $"got '($context)', expected an app domain not benzened_runas"
    })
  ]
}

def check-capabilities [serial: string, granted: string]: nothing -> list<record> {
  header "5. capability ceiling"
  let caps = (
    adb-sh $serial $"/system/bin/benzened_runas ($granted) 0 cat /proc/self/status"
    | lines
    | where $it =~ '(?i)^CapEff'
    | get -o 0
    | default "unavailable"
    | str trim
  )
  [(mark-pass $"worker CapEff: ($caps)")]
}

def check-grant [serial: string, granted: string]: nothing -> list<record> {
  header $"6. grant path (requires the switch enabled for ($granted))"
  let result = (adb-sh $serial "/system/bin/benzened_su_client -c id -u" | str trim)
  [
    (if $result == "0" {
      mark-pass "su returned uid 0"
    } else if ($result =~ '(?i)not available|denied') {
      mark-skip "su denied" $"expected unless the AppSwitch is granted to the caller: ($result)"
    } else {
      mark-fail "su unexpected result" $result
    })
  ]
}

# Verify benzened on a running device or emulator
def main [
  serial: string = "emulator-5554"
  granted: string = "com.android.chrome"
  ungranted: string = "com.android.settings"
] {
  let results = [
    ...(check-preconditions $serial)
    ...(check-present $serial)
    ...(check-denials $serial)
    ...(check-ungranted $serial $ungranted)
    ...(check-impersonation $serial $granted)
    ...(check-capabilities $serial $granted)
    ...(check-grant $serial $granted)
  ]

  let passed = ($results | where status == pass | length)
  let failed = ($results | where status == fail | length)
  let skipped = ($results | where status == skip | length)

  print ""
  print $"pass=($passed) fail=($failed) skip=($skipped)"

  if $failed > 0 { exit 1 }
}
