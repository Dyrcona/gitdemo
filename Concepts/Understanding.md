# Understanding How Git Works #

We approach an understanding of how Git works from the outside in.

## Repositories ##

At the outermost level, code is organized into repositories.  A Git
repository has the same function as any other repository does in the
real world: a place where stuff is stored.  Git repositories come with
the added bonus of very good inventory control in the form of the
various git commands used to manage the objects stored in the
repository.  So much so that Git tracks not only the current
configuration of these objects, but their past incarnations as well.

Users create new repositories with the `init` and `clone` subcommands.
The first initializes a new repository and the latter copies an
existing repository.  One has to establish a repository before working
with Git.

The code within a repository is generally related to a single project.
However, unrelated code can be introduced into a repository in the
form of branches, and some repositories, the Evergreen project's
[random repository](https://git.evergreen-ils.org/?p=working/random.git;a=summary)
for example, hold only loosely related code.

## Branches ##

Branches organize the code within a repository.  The main branch,
often called "master" or "trunk," represents the principal line of
development in a project.  Developers work on new features and bug
fixes in separate branches until the changes are ready to be merged
into the main branch.  One can make as many branches as required.
Branches can be deleted as well as shared between repositories.

Branches are typically manipulated using the `branch`, `checkout`, and
`switch` subcommands of git.

As explained below, git manages branches by reference to other
objects.

## Objects ##

Git stores objects, not files, in what amounts to an object database.
Three types of objects represents the kind of data that git stores:
binary data, filesystem metadata, and commits.  These objects are
organized in the `objects` subdirectory of the git directory in the
repository.

For more complete documentation of Git objects see [Git Internals -
Git Objects in Pro Git](https://git-scm.com/book/en/v2/Git-Internals-Git-Objects).

### blob ###

A `blob` stores the raw data of an object in git.  These are usually
the contents of a given file or files, but it is possible to add any
arbitrary data as a blob object, though it may not stick around long.
A blob stores the current contents of the object and is identified by
the SHA-1 hash of the content.  If two files have the same content,
then they are represented by the same blob.

### tree ###

The `tree` object stores the filesystem information about a group of
files.  This information includes the file permissions mode, object
type, object hash, and filesystem path for the object.  For example,
the tree object of the main branch of this repository looked like the
following at one point in time:

    git cat-file -p main^{tree}
    040000 tree fcd3b97b835b79472f8caa482fa32be9203cd948	Concepts
    040000 tree ee7fbb01498bd0dcaf356de300d268876ee9f6f6	Examples
    100644 blob f5c5efd8860e2409de68861b0f781a59e98bf338	README.md
    100644 blob 7be1b73aa07cdb4305c8e5efe65429b63e2254c2	References.md
    100644 blob 275b5ef5f858eec7a410c6603590ce84da3a9ad7	Start.md

### commit ###

The `commit` object stores the information relevant for a commit.
This includes the hash of the tree object being committed, the hash of
the parent, usually previous, commit object, information about the
author, committer, and time of the commit, as well as the commit
message.

## References ##

Git stores references in the `refs` subdirectory.  References point to
git objects and offer a sort of shorthand for referring to them.

### heads ###

The `heads` references store the hashes of the most recent commit
objects for branches.  There will be a file here for each extant
branch in your local repository.  The contents of the file is the hash
of the commit that represents the top of the branch.

Branch refs will change as commits are added or modified on the
branch.

#### HEAD ####

A special reference called `HEAD` exists in the root of the `gitdir`,
usually `.git/HEAD`.  This reference refers to the top commit of the
currently checked out branch, also known as the head of the branch.
With the main branch of this repository checked out, it looks like
this:

    ref: refs/heads/main

It normally references another branch reference in the `heads`
directory.  When it references a commit directly, you are working in a
"detached HEAD" state. Git will inform you when your work enters this
state.  This sometimes occurs by accident, and you normally fix it by
switching to an actual branch.

The detached head state can be useful for making experimental changes,
testing them locally, and committing them.  If you decide that you
want to keep these changes it is advisable to create a new branch
based on your current state.

### remotes ###

References to remote repository branches are stored in the
`refs/remotes`subdirectory.  These function much like the local branch
references in `heads`.  However, each remote repository gets its own
subdirectory.  Also, the referenced commits may not necessarily be
available locally.  In order to make the commit available, the remote
branch needs to be checked out unless the remote branch is already
identical to a local branch.

### tag ###

A `tag` reference also points to a commit.  However, unlike a branch
references in heads, a tag reference always points to the same commit.
A tag marks a particular milestone in development, such as the code
used for a given release of a program.  A tag can be simple or
annotated as well as signed or unsigned.  An annotated tag includes a
message related to the reason for the tag, and a signed tag includes
the signature of the committer.

### stash ###

Finally, the `stash`, if any, is a reference, or references, to
temporary objects created via the `git stash` command.

## Packfiles ##

Git aggregates similar objects into a more efficient storage called a
`packfile`.  The packfile is a compressed representation of the data
in the objects and will further be streamlined by tracking the
differences between objects rather than the entire contents of each
blob.  When Git creates packfiles, an index file is included for fast
access to the contents.  Packfiles are created when git determines
that there are too many loose objects in your repository and at
various other times, such as possibly when pushing to a remote
repository, or if you run `git gc` or `git repack` manually.

An understanding of packfiles is not strictly necessary for daily
usage of Git.  However, if you go poking around in the nonpublic areas
of a git repository, you may see them.

For more information on Git packfiles see [Git Internals - Packfiles
in Pro Git](https://git-scm.com/book/en/v2/Git-Internals-Packfiles).
