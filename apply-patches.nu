#!/usr/bin/env nu

# Apply the BenzeneOS recovered security patches across the AOSP tree.
#
# The patches carry tree-root-relative paths (frameworks/base/core/...), but each
# one has to land inside the repo project that owns those files, so -p is derived
# per project rather than fixed. A patch touching two projects is applied to each
# in turn, filtered to that project's files.

const default_patch_dir = 'vendor/benzeneos/patches'
const patch_author = 'security@benzeneos.org'

# Applied patches are derived state, not work worth keeping.
def applied-commits [root: string, projects: list<string>]: nothing -> list {
    mut found = []
    for project in $projects {
        let dir = ($root | path join $project)
        if not ($dir | path join '.git' | path exists) { continue }
        let count = (
            (^git -C $dir log $'--author=($patch_author)' --format=%H | complete).stdout
            | lines | where {|l| ($l | str trim) != '' } | length
        )
        if $count == 0 { continue }
        let foreign = (
            (^git -C $dir log -n $count --format=%ae | complete).stdout
            | lines | where {|l| ($l | str trim) != $patch_author } | length
        )
        $found = ($found | append {project: $project, count: $count, foreign: $foreign})
    }
    $found
}

def find-tree-root [] {
    mut dir = ($env.PWD | path expand)
    loop {
        if ($dir | path join '.repo' | path exists) { return $dir }
        let parent = ($dir | path dirname)
        if $parent == $dir { break }
        $dir = $parent
    }
    error make {msg: $'no .repo found at or above ($env.PWD)'}
}

# Tree-root-relative paths a patch touches. Thirteen of these are plain unified
# diffs with no `diff --git` line, so both header styles have to be read.
def patch-targets [file: string]: nothing -> list<string> {
    open $file
    | lines
    | where {|line| ($line | str starts-with 'diff --git a/') or ($line | str starts-with '--- a/') }
    | each {|line|
        if ($line | str starts-with 'diff --git a/') {
            $line | parse 'diff --git a/{path} b/{other}' | get path.0?
        } else {
            $line | str substring 6..
        }
    }
    | compact
    | uniq
}

# Longest project prefix wins, so packages/modules/Nfc beats packages.
def owning-project [target: string, projects: list<string>]: nothing -> string {
    $projects
    | where {|p| $target == $p or ($target | str starts-with $'($p)/') }
    | reduce --fold '' {|p, acc| if ($p | str length) > ($acc | str length) { $p } else { $acc } }
}

# Projects get split and moved between releases.
def resolve-project [target: string, projects: list<string>]: nothing -> string {
    let direct = (owning-project $target $projects)
    if $direct != '' { return $direct }
    let parts = ($target | split row '/')
    if ($parts | length) < 3 { return '' }
    owning-project (($parts | first) + '/' + ($parts | skip 2 | str join '/')) $projects
}

# One step per (patch, project), in filename order. That order already satisfies
# every inter-patch dependency, which is why no explicit series file is needed.
def build-plan [patches: list<string>, projects: list<string>]: nothing -> list {
    $patches | each {|patch|
        let targets = (patch-targets $patch)
        let owners = ($targets | each {|t| resolve-project $t $projects } | where {|o| $o != '' } | uniq)

        if ($owners | is-empty) {
            [{patch: $patch, name: ($patch | path basename), project: '', depth: 0, rels: $targets}]
        } else {
            $owners | each {|project|
                let rels = (
                    $targets
                    | where {|t| $t == $project or ($t | str starts-with $'($project)/') }
                    | each {|t| $t | str substring (($project | str length) + 1).. }
                )
                {
                    patch: $patch
                    name: ($patch | path basename)
                    project: $project
                    depth: (($project | split row '/' | length) + 1)
                    rels: $rels
                }
            }
        }
    } | flatten
}

# Check the whole series against throwaway copies of only the files it touches,
# so a patch that builds on an earlier one is checked against the earlier one's
# result rather than against a pristine tree.
def check-plan [plan: list, root: string]: nothing -> list {
    let tmp = (^mktemp -d | str trim)

    for group in ($plan | where project != '' | group-by project | transpose project steps) {
        let workdir = ($root | path join $group.project)
        let dest = ($tmp | path join $group.project)
        mkdir $dest

        let rels = ($group.steps | get rels | flatten | uniq)
        let tracked = (^git -C $workdir ls-tree -r --name-only HEAD -- ...$rels | lines | where {|l| $l != '' })

        if not ($tracked | is-empty) {
            let archive = ($tmp | path join 'project.tar')
            ^git -C $workdir archive --format=tar -o $archive HEAD -- ...$tracked
            ^tar -xf $archive -C $dest
            rm -f $archive
        }
    }

    mut results = []
    for step in $plan {
        if $step.project == '' {
            $results = ($results | append {patch: $step.name, project: '-', status: 'no-project', detail: ($step.rels | str join ' ')})
            continue
        }
        let includes = ($step.rels | each {|r| $'--include=($r)' })
        let outcome = (^git -C ($tmp | path join $step.project) apply $'-p($step.depth)' ...$includes $step.patch | complete)
        $results = ($results | append (step-result $step $outcome))
    }

    rm -rf $tmp
    $results
}

def apply-plan [plan: list, root: string]: nothing -> list {
    mut results = []
    for step in $plan {
        if $step.project == '' {
            $results = ($results | append {patch: $step.name, project: '-', status: 'no-project', detail: ($step.rels | str join ' ')})
            continue
        }
        let workdir = ($root | path join $step.project)
        let includes = ($step.rels | each {|r| $'--include=($r)' })
        let outcome = (^git -C $workdir am $'-p($step.depth)' ...$includes $step.patch | complete)
        if $outcome.exit_code != 0 { do -i { ^git -C $workdir am --abort } }
        $results = ($results | append (step-result $step $outcome))
    }
    $results
}

def step-result [step: record, outcome: record]: nothing -> record {
    if $outcome.exit_code == 0 {
        {patch: $step.name, project: $step.project, status: 'ok', detail: ''}
    } else {
        let detail = ($outcome.stderr | lines | where {|l| ($l | str trim) != '' } | first | default 'failed')
        {patch: $step.name, project: $step.project, status: 'failed', detail: $detail}
    }
}

# Apply every patch in the patch directory, one commit per patch per project.
def main [
    --patch-dir: string = $default_patch_dir  # patch directory, relative to the tree root
    --dry-run                                 # report what would apply, change nothing
    --reset                                   # drop a previous run's patch commits first
    --undo                                    # drop a previous run's patch commits and stop
]: nothing -> nothing {
    let root = (find-tree-root)
    let dir = ($root | path join $patch_dir)

    if not ($dir | path exists) {
        error make {msg: $'($patch_dir) is not in the tree — run: repo init -g default,benzene-patches; repo sync'}
    }

    if not $dry_run {
        let identity = (^git -C $root config user.email | complete)
        if $identity.exit_code != 0 or ($identity.stdout | str trim) == '' {
            error make {msg: 'git user.email is unset, so git am cannot commit — set it before applying'}
        }
    }

    let projects = (
        $root | path join '.repo' 'project.list'
        | open | lines | where {|l| ($l | str trim) != '' }
    )
    let patches = (glob ($dir | path join '**' '*.patch') | sort)

    if ($patches | is-empty) {
        error make {msg: $'no .patch files under ($dir)'}
    }

    let plan = (build-plan $patches $projects)
    let targets = ($plan | where project != '' | get project | uniq)

    let applied = (applied-commits $root $targets)
    let total = (if ($applied | is-empty) { 0 } else { $applied | get count | math sum })

    if not ($applied | is-empty) {
        let unsafe = ($applied | where foreign > 0)
        if not ($unsafe | is-empty) {
            print ($unsafe | select project count foreign)
            error make {msg: 'patch commits are interleaved with other work, refusing to touch them'}
        }
        if $dry_run {
            print $'note: ($total) patch commits are already applied, so failures below are stale rather than real'
        } else if $reset or $undo {
            for p in $applied {
                ^git -C ($root | path join $p.project) reset --hard $'HEAD~($p.count)' | complete | ignore
            }
            print $'reset ($total) patch commits across ($applied | length) projects'
            if $undo { return }
        } else {
            error make {msg: $'($total) patch commits from a previous run are already applied across ($applied | length) projects — re-run with --reset'}
        }
    } else if $undo {
        print 'no patch commits applied, nothing to undo'
        return
    }

    print $'($patches | length) patches, ($targets | length) projects, across ($root)'

    let results = if $dry_run { check-plan $plan $root } else { apply-plan $plan $root }
    let failures = ($results | where status != 'ok')

    print $'ok: ($results | where status == ok | length)   failed: ($failures | length)'

    if not ($failures | is-empty) {
        print ''
        print ($failures | select patch project detail)
        exit 1
    }
}
