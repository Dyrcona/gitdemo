# Configuration #

Stored at multiple levels: system, global (user), local (repository), or worktree.

You can use the `-c` option to override settings on per command basis.

Configuration is local and not shared with remote repositories.

Configuration files can be edited by hand, but are more commonly
manipulated using the `git config` command.  This demo/tutorial
emphasizes using the latter approach to managing configuration.

## Configuration File Format ##

The Git configuration file uses a simple text syntax resembling an
[INI File](https://en.wikipedia.org/wiki/INI_file).  The configuration
consists of name/value pairs of variables divided into sections and
subsections.  Variables must appear in a section or subsection.  The
file may contain comments that are introduced by either the `#` or `;`
characters and continue to the end of the current line.

For more detailed information,
[see the documentation](https://git-scm.com/docs/git-config#_configuration_file).

## File Scopes ##

### System ###

The system wide configuration file is stored in
`$(prefix)/etc/gitconfig`, this is typically just `/etc/gitconfig` on
most systems.  This file is usually empty.  If it contains values,
then they were likely put there by a system administrator or some
software other than git itself.

The system scope is set via the `--system` file option to `git config`.

### Global ###

The "global" or user configuration is found in the default location
for user configuration files.  This is typically a file named
`.gitconfig` in the user's home directory or in
`$XDG_CONFIG_HOME/git/config`, where `XDG_CONFIG_HOME` is typically the
same as `$HOME/.config` on a GNU/Linux system.

A global configuration might look something like this:

<pre>
[push]
	default = simple
[user]
	email = jason@sigio.com
	name = Jason Stephenson
	signingKey = 73C4C35C7E2B970ACC679A4CD8800BE5008CB35A
[core]
	autocrlf = input
[alias]
	brief = log --abbrev-commit --pretty=oneline
[init]
	defaultBranch = main
[include]
	path = ~/CWMARS/utilities/gitconfig
</pre>

The global scope is set via the `--global` file option to `git config`.

### Local ###

The local configuration is stored per repository.  It is found in
`.git/config` in a normal, working repository or `config` in a bare
repository.  It controls settings specific to the current repository
and overrides the system and global settings in the repository.  Below
is an example for a clone of this `gitdemo` repository on the author's
computer:

<pre>
[core]
	repositoryformatversion = 0
	filemode = true
	bare = false
	logallrefupdates = true
[remote "origin"]
	url = git@github.com:Dyrcona/gitdemo.git
	fetch = +refs/heads/*:refs/remotes/origin/*
[branch "main"]
	remote = origin
	merge = refs/heads/main
</pre>

The `config` of a bare, remote repository might look like this:

<pre>
[core]
	repositoryformatversion = 0
	filemode = true
	bare = true
	sharedrepository = 1
[receive]
	denyNonFastforwards = true
</pre>

The local scope is the default if no file option is specified.  It can
be explicitly set via the `--local` file option to `git config`.

### Worktree ###

Git can store separate configurations for different worktrees in the
main repository if the `extensions.worktreeConfig` setting is
`true`. This options is only useful if you are using worktrees in your
workflow.  If you are not using worktrees, or the
`extensions.worktreeConfig` setting is `false` or not set, then this
option is the same as local.

Configuration for worktrees is stored in `.git/worktrees/<id>/config`
of the main worktree. See `git help config` and `git help worktree`
for more information.

The worktree scope is set via the `--worktree` file option to `git config`.

### The --file Option ###

You can specify that git read configuration from, or write to, a
specific file using the `--file <filename>` option.  Git will not
automatically read configuration options from this file when running
commands, so it is rarely used.  The `--file` option might be most
useful when creating files to include in other configurations or to
share with others.

## Command Line Override ##

One can run any git subcommand with the `-c` option to the git program
itself to override any particular configuration options.  The example
below would override the `defaultBranch` setting from the global
configuration example shown above.  The new repository will be
initialized with the default branch named "dev" instead of "main."

    git -c init.defaultBranch=devel init testrepo

## git config ##

The `git config` subcommand is used to view and to manipulate
manipulate configuration values.

### Synopsis ###

<pre>
       git config [<file-option>] [--type=<type>] [--fixed-value] [--show-origin] [--show-scope] [-z|--null] <name> [<value> [<value-pattern>]]
       git config [<file-option>] [--type=<type>] --add <name> <value>
       git config [<file-option>] [--type=<type>] [--fixed-value] --replace-all <name> <value> [<value-pattern>]
       git config [<file-option>] [--type=<type>] [--show-origin] [--show-scope] [-z|--null] [--fixed-value] --get <name> [<value-pattern>]
       git config [<file-option>] [--type=<type>] [--show-origin] [--show-scope] [-z|--null] [--fixed-value] --get-all <name> [<value-pattern>]
       git config [<file-option>] [--type=<type>] [--show-origin] [--show-scope] [-z|--null] [--fixed-value] [--name-only] --get-regexp <name-regex> [<value-pattern>]
       git config [<file-option>] [--type=<type>] [-z|--null] --get-urlmatch <name> <URL>
       git config [<file-option>] [--fixed-value] --unset <name> [<value-pattern>]
       git config [<file-option>] [--fixed-value] --unset-all <name> [<value-pattern>]
       git config [<file-option>] --rename-section <old-name> <new-name>
       git config [<file-option>] --remove-section <name>
       git config [<file-option>] [--show-origin] [--show-scope] [-z|--null] [--name-only] -l | --list
       git config [<file-option>] --get-color <name> [<default>]
       git config [<file-option>] --get-colorbool <name> [<stdout-is-tty>]
       git config [<file-option>] -e | --edit
</pre>

### Specifying Variable Names ###

Variable names are specified as `<section>.<subsection>.<variable>` on
the command line where the subsection and its trailing period are only
required when there is a valid subsection.  This form is used anywhere
that `<name>` appears in the synopsis above.

### Getting Variable Values ###

You can query the current value of a setting by typing `git config
<name>`.  For instance to see the current `user.email` value you
would type the following:

    git config user.email

When getting values, `git config` searches the files in order from
least (system) to most (local or worktree) specific scope.  You can,
of course, limit the look up to a given scope using the appropriate
file scope option.

### Setting Variable Values ###

Values are set by adding a value after the configuration key name on
the command line.  The default, if no file scope is specified, is to
update the configuration of the current repository.

You could cause the `git push` command to automatically set upstream
tracking of branches in a given repository by running the following:

    git config push.autoSetupRemote true

It is a good practice to configure the `user.name` and `user.email`
options globally for any accounts where you will use git to make
commits:

    git config --global user.name 'Your Name'
    git config --global user.email email@hostname.tld

Naturally, you replace "'Your Name'" with your name and
"email@hostname.tld" with your actual email address.  If you don"t set
these values, git will have to query the operating system based on the
user account that is running the git commands.  This value may or may
not be what you want if you are using a shared or system account.

### Adding Variable Values ###

Some variables can have multiple values.  These are stored one per
line in the relevant section of the configuration file, for instance:

<pre>
[include]
	path = /path/to/foo.inc
	path = ~/foo.inc
</pre>

Assuming values like the above, we could add `foo.inc` from the
repository root directory with the following command:

    git config --add include.path foo.inc

The previous config chunk would subsequently look like this:

<pre>
[include]
	path = /path/to/foo.inc
	path = ~/foo.inc
	path = foo.inc
</pre>

### Unsetting Variable Values ###

Single values can be unset with the simple syntax:

    git config --global --unset user.name

The above works for variables with multiple values when only 1 is set.
However, if we attempt to unset a variable with multiple values using
the above syntax, Git will warn us and do nothing:

    git config --unset include.path
    warning: include.path has multiple values

Assuming that we want to remove just 1 of the include paths, we need
to add its value with a regular expression so that git knows which to
unset:

    git config --unset include.path '^foo.inc$'

The above will unset only the latest one that we add matching 'foo.inc':

<pre>
[include]
	path = /path/to/foo.inc
	path = ~/foo.inc
</pre>

Alternately, we could unset all the include settings matching 'foo.inc' like so:

    git config --unset-all include.path foo.inc

### Removing Sections ###

You can remove an entire configuration section in one go using the
`--remove-section` option.  If we decided that we no longer need any of
the includes that we added previously, we could remove the `[include]`
section from our local configuration like so:

    git config --remove-section include

### Listing Values ###

You can list all of the currently effective configuration values with
the `--list` option.  By default it shows everything relevant in the
current scope.  When run in this repository on the author's computer,
the output looks like this:

<pre>
git config --list

push.default=simple
user.email=jason@sigio.com
user.name=Jason Stephenson
user.signingkey=73C4C35C7E2B970ACC679A4CD8800BE5008CB35A
core.autocrlf=input
alias.brief=log --abbrev-commit --pretty=oneline
init.defaultbranch=main
include.path=~/CWMARS/utilities/gitconfig
alias.cwcommit=-c author.email=jstephenson@cwmars.org -c committer.email=jstephenson@cwmars.org commit
core.repositoryformatversion=0
core.filemode=true
core.bare=false
core.logallrefupdates=true
remote.origin.url=git@github.com:Dyrcona/gitdemo.git
remote.origin.fetch=+refs/heads/*:refs/remotes/origin/*
branch.master.remote=origin
branch.master.merge=refs/heads/master
branch.main.remote=origin
branch.main.merge=refs/heads/main
user.email=jason@sigio.com
</pre>

You can also limit the output using an appropriate file option, such
as `--sytem`, `--global`, or `--local`

### Help ###

The above example document the most basic usage of `git config`.  You
should run `git help config` to read the full documentation.

## Aliases ##

The `git config` command is also used to set up [command
aliases](Alias.md).
