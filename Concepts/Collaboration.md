# Collaborating With Others #

## Adding Remote Repositories ##

    git remote add <name> <URL>

If you added the remote with a read-only URL, and you want to be able
to push, and you have permission to push to that remote, then you can
add a new URL for pushing to the remote like so:

    git remote set-url --push <name> <pushURL>

Remotes can be added, deleted, and otherwise managed with the `git
remote` command.  See `git help remote` for more information.

## Getting Code ##

Running `git fetch` immediately after adding a new remote will add
references to the remote branches into your repository's `.git`
directory.  You fetch a single remote's references by specifying the
remote repository's local name.

    git fetch <name>

New references and changes on remote repositories do not automatically
propagate to your local repository.  You should `git fetch`
periodically to keep your local view of the remotes up to date.

`git checkout` allows you to check out local copies of remote
branches.

    git checkout -b <localBranch> <name>/<remoteBranch>

## Sending Code ##

When you have changes in a branch that you want to share with others,
you do so via `git push`.

    git push <name> <localBranch>

If you need to rename *localBranch* on the remote, then that is
accomplished like so:

    git push <name> <localBranch>:<remoteBranch>

See `git help push` for more options that you may find useful.

## Keeping Up to Date ##

It is a good idea to begin every work session with the following
command:

    git fetch --all

This updates your local repository's view of all of its remote
references.

If the base branch of one that you are working on changes, it would be
wise for you to rebase your work on the remote branch to the latest
changes.  Say a developer is working on a new feature in the local
branch called *newFeature* and this local branch is based on the
origin branch *main*.  If *main* changes while the work is in
progress, the developer could run one of the following commands to
update the *newFeature* branch:

    git rebase origin/main newFeature

or if the *newFeature* branch is already checked out:

    git rebase origin/main

Either command will leave the newFeature branch checked out.

Additionally, Git will warn you if you checkout a local branch that
tracks a remote branch and there are outstanding changes.

<pre>
Switched to branch 'master'
Your branch is behind 'origin/master' by 2 commits, and can be fast-forwarded.
  (use "git pull" to update your local branch)
</pre>

As the message above suggests, you use `git pull` to update your local branch.
