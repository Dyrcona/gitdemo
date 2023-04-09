# Subcommand Aliases #

If there are certain git subcommands that you run often with
particular options, you can add an alias to your configuration so that
you will have less typing to do.  Like any other configuration option,
an alias can be added to the system, global, or local configuration.

An alias takes the form of `alias.[alias-name] [subcommand with
options]`. The `alias-name` becomes an alias (or shortcut) to execute
the existing `subcommand with options`.

Below is an example that I have found useful because I often want to
see the current branch's history in as compact a form as possible:


    git config --global alias.brief \
    'log --abbrev-commit --pretty=oneline'


We have to quote the `subcommand with options` when adding the alias
via the command line, particularly via a shell on Linux or some
similar operating system.  I use single quotes in the examples here,
but double quotes would also work.  You have to follow the quoting
conventions of whatever shell you use.

If you add the alias directly to the git config file, then you do not
have to quote the subcommand and options.  For instance, the `brief`
alias looks like the following when it is the first one in the config
file:

<pre>
[alias]
	brief = log --abbrev-commit --pretty=oneline
</pre>

Once you have added the alias, git will actually do `git log
--abbrev-commit --pretty=oneline` whenever you type `git brief`.

Since the alias is a shortcut for another git subcommand, you can also
give it any other options accepted by the subcommand.  For example, if
you want to add the merge graph to the above compact representation,
you can run:

    git brief --graph

If you want to find the commit that added a certain file or directory,
this will serve the purpose:

    git brief --reverse -- path/to/file

The above will produce the brief log output in reverse order for the
given file.

You can pass any other options of the `git log` subcommand to the `git
brief` alias and they will work as appropriate.  Naturally, you won't
to add any contradictory options as they may not work as expected.

If you always want to add "Signed-off-by:" to your commits, then you
might add:

    git config --global alias.cs 'commit -s'

You could do likewise for `cherry-pick`:

    git config --global alias.ps 'cherry-pick -s'

If you work on one project in particular that has a policy of
requiring "Signed-off-by:" then you might add those just to that
project's repositories by omitting the `--global` flag.

Aliases do not have to begin with a subcommand.  You can begin them
with options to the `git` command.  For instance, the author has an
alias to run `commit` with a specific email address:

    git config --global alias.cwcommit \
    '-c author.email=jstephenson@cwmars.org -c committer.email=jstephenson@cwmars.org commit'

If you ever want to remove an alias, you can do so with the `--unset`
option to `git config` as if it were any other configuration setting:

    git config --global --unset alias.brief

for example.
