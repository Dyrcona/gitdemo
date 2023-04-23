# Repositories #

At the outermost level, Git organizes code into repositories.  A Git
repository has the same function as any other repository in the real
world: a place where stuff is stored.  Git repositories come with the
added bonus of very good inventory control in the form of the various
git commands used to manage the objects stored in the repository.  So
much so that Git tracks not only the current configuration of these
objects, but their past incarnations as well.

The code within a repository is generally related to a single project.
However, unrelated code can be introduced into a repository in the
form of branches, and some repositories, the Evergreen project's
[random repository](https://git.evergreen-ils.org/?p=working/random.git;a=summary)
for example, hold only loosely related code or documents.

Users create new repositories with the `git init` and `git clone`
subcommands.  The first initializes a new repository and the latter
copies an existing repository.  One must establish a repository before
doing anything truly meaningful with Git.

## Repository Layout ##

A typical repository contains working files and a `.git` subdirectory
where git does its work.  For instance, the root of this repository
looked like this at one point in time:

<pre>
Concepts/
Examples/
.git/
.gitignore
README.md
References.md
Start.md
</pre>

Its `.git` directory looked like this:

<pre>
branches/
COMMIT_EDITMSG
config
description
FETCH_HEAD
HEAD
hooks/
index
info/
logs/
objects/
ORIG_HEAD
packed-refs
refs/
</pre>

### Bare Repository Layout ###

A bare repository lacks working files and contains only the files and
subdirectories of the `.git` directory at the top level.  Bare
repositories typically serve as the remote endpoints where users
collaborate on a project.  Most of the remote repositories that you
interact with on servers will be bare repositories.

<pre>
branches/
config
description
HEAD
hooks/
info/
objects/
refs/
</pre>

## Creating a New Repository ##

Three common reasons for creating a new repository include you have
some existing code that you want to add to git, you are starting a new
project and you want to make the repository before you start adding
files, or you want to share your code with others, or even just
yourself.  We document those case below.

### Case 1: Existing Files/Project ###

    cd /path/to/project
    git init
    git add .
    git commit -m 'Initial Commit'

We talk more about the `git add` and `git commit` commands in
[Commits](Commits.md).

### Case 2: Starting from Scratch ###

    git init <projectname>

With this one, `git init` will make the *projectname* directory for
you if you specify it.  Otherwise, you can make that directory
yourself, `cd` into it and just run `git init`.

### Case 3: Remote Repository ###

When you want a remote repository, you usually want a bare repository.
The simplest bare repository, usable only by the user who created it,
can be initialized with `git init --bare`.  A shared repository that
allows anyone in the same group to use it could be created with the
following command:

    git init --bare --shared=true

The `--shared` option takes a few other values, such as `all` or an
octal permission mask that specify who can access the repository.  In
the case of group access, you'll want to use an existing group, or
create a new group, that can access the repository and add the users
who need to access the repository to that group.  The `all` parameter
option sets the repository so that any user on the remote system may
access the repository.  You can often avoid such issues by using a
[hosted Git solution](Hosting.md).

### Other Options ###

`git init` has other options that you might find useful:

  * `--separate-git-dir=<directory>` can be useful for a web site or
    other "live" repository where you want to push changes, but you
    want to keep the git metadata files in a separate location.
  * `-b --initial-branchname=<branch-name>` either can be used to
    specify the initial branch name if you want to change it from the
    default.

For more information, see `git help init`.

## Cloning an Existing Repository ##

The most common use of `git clone` is to make a local working copy of
a shared remote repository.

    git clone https://github.com/Dyrcona/gitdemo.git

Will clone this repository from GitHub into a local directory called
*gitdemo*, for example.  If you want to change the local directory
name, you can specify it on the command line after the remote URL.

    git clone https://github.com/Dyrcona/gitdemo.git projects/gitdemo

The above will put it in a subdirectory of the *projects* directory in
the current directory.  You can specify any path you like, so long as
you have permission to write the filesystem location.

When you clone a repository, the new repository gets a [remote
reference](Understanding.md#remotes) to the source repository called
*origin*.  You can change the name of this reference when cloning, by
specifying the `-o <name>` option.  For example, if you want to call
the original repository *source* instead of *origin*, the following
example would work:

    git clone -o source https://github.com/Dyrcona/gitdemo.git

By default, the clone repository with have the branched referenced by
[HEAD](Understanding.md#HEAD) in the source repository checked out.
You can change this by specifying the `-b <branch>` option to clone.
For instance, let's assume that we want a clone of the Evergreen ILS
main repository and we only care about the `rel_3_10` development
branch.  We could run the following command to clone a repository with
that branch checked out:

    git clone -b rel_3_10 git://git.evergreen-ils.org/Evergreen.git Evergreen/rel_3_10

When you clone a repository, you do not normally get a copy of
everything in the original.  One branch will typically be checked out
and available for use.  Instead, references to the other remote
branches are copied, but not the branches and commits to which they
point.

### Other Options ###

`git clone` has a number of other useful options, including `--bare`
and `--separate-git-dir` which function just like the same options to
`git init`.  In addition to these, there are options to override
linking of files when make cloning local repositories, option to
filter the contents of the checked out branch, and the `--mirror`
option which makes a local bare repository with all of the branches
and objects from the original repository.
