# Branches #

Branches organize the code within a repository.  The main branch,
often called *master*, *trunk*, or *main*, represents the principal
line of development in a project.  Developers work on new features and
bug fixes in separate branches until the changes are ready to be
merged into the main branch.  One can make as many branches as
required.  Branches can be deleted as well as shared between
repositories.

Branches are typically manipulated using the `branch`, `checkout`, and
`switch` subcommands of git.

## Making New Branches ##

The following three operations are almost equivalent:

    git checkout -b time-machine_exp
    git switch -c time-machine_exp
    git branch time-machine_exp

All 3 of them create a new branch named *time-machine_exp* based on
the currently checked out branch.  The first two also checkout that
branch so that it can be used immediately, while the third create the
branch but does not check it out.

If you want to make a new branch that is based on some branch other
than the current branch, you can specify the other branch name, or
even a commit:

    git checkout -b time-machine_exp quantum-bridge
    git switch -c time-machine_exp quantum-bridge
    git branch time-machine_exp quantum-bridge

Remote branches can be checked out locally, in the same fashion.  You
can give the remote branch any local name that you want.

    git checkout -b custom_rel_3_10 origin/evergreen/custom_rel_3_10
    git switch -c custom_rel_3_10 origin/evergreen/custom_rel_3_10
    git branch -t custom_rel_3_10 origin/evergreen/custom_rel_3_10

## Switching Branches ##

    git checkout time-machine_exp
    git switch time-machine_exp

## Tracking Remote Branches ##

Local branches can track remote branches.  This is the default case
when you make local branches by checking out a remote branch as in the
*custom_rel_3_10* example above.  In some cases, you may want to
change the upstream branch for a local branch, or you may need to set
it because of how the local and remote branches were created.  In
either case you can use `git branch` to change the upstream branch for
a local branch.

    git branch -u origin/evergreen/custom_rel_3_10 custom_rel_3_10

By setting your local branches to track an upstream branch, you can
keep your local branch up to date using `git pull`.

## Branch Maintenance ##

Branches can be renamed

    git branch -m time-machine_exp time-machine_wip
    git branch -M time-machine_wip # Renames the current branch

deleted

    git branch -D custom_rel_3_10

copied

    git branch -c time-machine_new time-machine_wip

and more!

See `git help branch` for more information.
