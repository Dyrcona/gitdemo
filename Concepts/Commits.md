# Committing Changes #

Once you've made some changes, and you are satisfied with them, you
may decide that it is time to commit these changes to your repository.

## git status ##

Before blindly committing all of the changes, one would be wise to see
what changes have been made with the `git status` command.  At one
point during the preparation of the documents in this repository, the
`git status` looked like this:

<pre>
On branch main
Your branch is ahead of 'origin/main' by 1 commit.
  (use "git push" to publish your local commits)

Changes not staged for commit:
  (use "git add &lt;file&gt;..." to update what will be committed)
  (use "git restore &lt;file&gt;..." to discard changes in working directory)
	modified:   Concepts/Understanding.md
	modified:   Start.md</span>

Untracked files:
  (use "git add &lt;file&gt;..." to include in what will be committed)
	Concepts/Branches.md
	Concepts/Commits.md
	Concepts/Repositories.md

no changes added to commit (use "git add" and/or "git commit -a")
</pre>

## git diff ##

You can review the changes not staged for commit with `git diff`.
Running it at this point produces the output below.

<pre>
diff --git a/Concepts/Understanding.md b/Concepts/Understanding.md
index 5449644dd8..5428af6d21 100644
--- a/Concepts/Understanding.md
+++ b/Concepts/Understanding.md
@@ -1,50 +1,12 @@
 # Understanding How Git Works #

-We approach an understanding of how Git works from the outside in.
-
-## Repositories ##
-
-At the outermost level, code is organized into repositories.  A Git
-repository has the same function as any other repository does in the
-real world: a place where stuff is stored.  Git repositories come with
-the added bonus of very good inventory control in the form of the
-various git commands used to manage the objects stored in the
-repository.  So much so that Git tracks not only the current
-configuration of these objects, but their past incarnations as well.
-
-Users create new repositories with the `init` and `clone` subcommands.
-The first initializes a new repository and the latter copies an
-existing repository.  One has to establish a repository before working
-with Git.
-
-The code within a repository is generally related to a single project.
-However, unrelated code can be introduced into a repository in the
-form of branches, and some repositories, the Evergreen project's
-[random repository](https://git.evergreen-ils.org/?p=working/random.git;a=summary)
-for example, hold only loosely related code.
-
-## Branches ##
-
-Branches organize the code within a repository.  The main branch,
-often called "master" or "trunk," represents the principal line of
-development in a project.  Developers work on new features and bug
-fixes in separate branches until the changes are ready to be merged
-into the main branch.  One can make as many branches as required.
-Branches can be deleted as well as shared between repositories.
-
-Branches are typically manipulated using the `branch`, `checkout`, and
-`switch` subcommands of git.
-
-As explained below, git manages branches by reference to other
-objects.
-
 ## Objects ##

-Git stores objects, not files, in what amounts to an object database.
-Three types of objects represents the kind of data that git stores:
-binary data, filesystem metadata, and commits.  These objects are
-organized in the `objects` subdirectory of the git directory in the
-repository.
+Git stores objects, not files, in what amounts to an object database,
+or content-addressable filesystem.  Three types of objects represents
+the kind of data that git stores: binary data, filesystem metadata,
+and commits.  These objects are organized in the `objects`
+subdirectory of the git directory in the repository.

 For more complete documentation of Git objects see [Git Internals -
 Git Objects in Pro Git](https://git-scm.com/book/en/v2/Git-Internals-Git-Objects).
diff --git a/Start.md b/Start.md
index c58d5438d9..ca9b522c36 100644
--- a/Start.md
+++ b/Start.md
@@ -10,6 +10,12 @@

 ## Basic Git Usage ##

+[Repositories](Concepts/Repositories.md)
+
+[Branches](Concepts/Branches.md)
+
+[Commits](Concepts/Commits.md)
+
 [Configuration](Concepts/Configuration.md)

 [Using Git with Evergreen](Concepts/Evergreen.md)
</pre>

After reviewing the above changes, the author decided to add the new
files and changed files in four separate commits: one for each the 3
untracked files, plus the 1 line change in Start.md that points to the
new document, and the fourth commit for the changes the *Understanding
How Git Works* document.  This was done with the following series of
commands:

    git add -p Start.md
    git add Concepts/Repositories.md
    git commit -s
    git add -p Start.md
    git add Concepts/Branches.md
    git commit -s
    git add Concepts/Understanding.md
    git commit -s
    git add Start.md
    git add Commits.md
    git commit -s

The above leads to a chain of discrete commits for each document.  All
of the changes could have been added in a single commit.  It is a
matter of taste which option to use.

## git add ##

Add all new and changed files:

    git add .

Add an individual file:

    git add path/to/file

Choose which pieces to add for a commit:

    git add -p

This opens your text editor and give you the opportunity to edit the
patch for the file.  There should be some explanatory text at the
bottom of the document, but to sum things up:

  * Removed lines begin with '-'.
  * Added lines begin with '+'.
  * Unchanged lines begin with ' '.
  * To keep removed lines, change '-' to ' ' on that line.
  * To remove added lines, delete them.
  * Do not touch unchanged lines!

These changes affect only what will be staged for this commit.  The
original changes remain in the document after the commit.  This is
handy if you've made a couple of unrelated changes in a document and
want to add them one at a time.

As always `git add` has more options.  See `git help add`.

> ### The Index ###
>
> The `git add` command stages changes for the next commit into the
> *index*.  The content of paths can be added as a whole or only parts
> of the changes can be added using the appropriate options.  The index
> holds a snapshot of the state at the time `git add` runs.  You can run
> `git add` multiple times to refresh the index and what will
> subsequently be committed.
>
> Staged changes for a particular file can be removed from the index via
> `git restore --staged <filepath>`.
>
> You can view the current state of the index via `git diff --cached`.

## git commit ##

Commit files that have been added:

    git commit

If you only have changed files that you want to commit, you can skip
`git add` and directly commit the changes with:

    git commit -a

You can add a `Signed-off-by:` line with your name and email address
by using the `-s` option.  A cryptographic signature can be added with
the `-S` (capital S) option.

See `git help commit` for more options and more details on using the
command.

> ### Writing Good Commit Messages ###
>
> Natalie Pina of freeCodeCamp
> [sums it up nicely](https://www.freecodecamp.org/news/how-to-write-better-git-commit-messages/#5-steps-to-write-better-commit-messages).
>
> The Evergreen Community has its own
> [recommendations for commit messages](https://wiki.evergreen-ils.org/doku.php?id=dev:git#commit_messages).

## Ignoring Files ##

Git can ignore files whose names or paths match certain patterns.
These patterns cane be added to files named `.gitignore`,
`.git/info/exclude`, or a file specified by the configuration option
`core.excludefile`.  You can put `.gitignore` files in any directory
and the one closest to the file being added takes precedence in the
case of conflict.

### Pattern Rules ###

  * Blank lines are ignored.
  * `#` as the first non-whitespace character on a line introduces a
    comment.  Otherwise, it is treated as a regular character.
  * A literal filename matches a file in any directory.
  * Directory names end in `/`.
  * Shell glob patterns can be used to match files that match patterns.
  * `!` inverts the meaning and matches the opposite of the rest of
    the line.

`!` is useful to override an entry from a higher level file.

You can match files that begin with `#` by preceding it with `\`.

### Files to Ignore ###

  * Compiler output and temporary build files, ex.: `*.o`
  * Editor backup and auto-save files: `\#*#`, `.#*`, `*.swp`, `*~`.
  * Temporary output of failed patches: `*.rej`, `*.orig`.
  * Anything else that you do not want Git to track!

## git revert ##

Commits can be undone with `git revert`.
