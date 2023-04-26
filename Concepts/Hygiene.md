# Git Hygiene #

## Moving and Removing Files ##

Use `git mv` to move or to rename a file:

    git mv <filename> <newfilename>
    git mv fileA subdirectory/fileA

Use `git rm` to delete a file:

    git rm fileB

Both commands stage the change in the index and do not take effect
until you run `git commit`.  The files are only deleted or renamed in
future commits.  They still exist in previous commits with the old
name.  [git filter-repo](https://github.com/newren/git-filter-repo/)
can be used To completely remove or rename a file in all previous
commits.

You can restore a deleted or moved file by checking out from a
previous commit where it existed.  For instance, you could recover
*fileB* in the next commit after the deletion:

    git checout HEAD^ -- fileB

## Garbage Collection ##

[git clean](https://git-scm.com/docs/git-clean)

[git gc](https://git-scm.com/docs/git-gc)

[git fsck](https://git-scm.com/docs/git-fsck)

