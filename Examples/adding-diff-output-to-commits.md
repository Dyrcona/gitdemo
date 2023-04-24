# Adding git diff Output to the Commits Document #

While editing the [Commits Document](../Concepts/Commits.md), the
author decided to add the `git diff` output for the changes used in
the example `git status` output.  Since the changes had been committed
previously, this required reaching back in history to get the working
directory into the state it had before those changes were added.

This is an example of forcing a detached HEAD state with git in order
to get some data from an earlier point in history.  Below are the
commands that were run to get the information to add to the document
and to return the current working state of the *main* branch.

    git checkout 6fd2515322
    git reset a7352e6c6f
    git diff > ../gitdemoscripts/diff.txt
    git reset --hard HEAD
    rm Concepts/Branches.md Concepts/Commits.md Concepts/Repositories.md
    git switch main

At this point, *Commits.md* is edited to insert the saved output and
add some explanatory text.  The changes are committed as normal.
