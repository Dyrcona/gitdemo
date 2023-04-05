# Git External Commands #

When you find yourself frequently running the same two or three git
subcommands in a row to accomplish a task, then you might want to add
your own subcommand to git.  One can add new subcommands to git by
writing a script or program and putting it in the executable search
path with a `git-` prefix in the name.

For example, a developer might frequently need to compare commits
between two branches and cherry-pick those from branch B into branch A
that they do not have in common.  In some cases, the developer might
even need to compare the commits from branch B against a third branch,
C, and cherry-pick those into branch A.  If the disjoint commits are
not all at the top of branch B, this could easily require multiple
steps, comparing git logs, using `git cherry` to see differences and
capturing the output into a file, possibly editing the file to provide
input to the cherry-pick or even to write a command line for the
cherry-pick command.  This could easily be wrapped up in a script and
put in your local `bin` as
[git-quickpick](https://gist.github.com/Dyrcona/4629200) or some
similar name.

If you are looking for inspiration or just want some additional
subcommands for git, then you might want to have a look at
[git-extras](https://github.com/tj/git-extras).  It is also available
as a package on Ubuntu.
