# Subcommand Aliases #

If there are certain git subcommands that you run often with
particular options, you can add an alias to your configuration so that
you will have less typing to do.  Like any other configuration option,
an alias can be added to the system, global, or local configuration.

An alias takes the form of `alias.[alias-name] [subcommand with
options]`. The `alias-name` becomes an alias (or shortcut) to execute
the existing `subcommand with options`.

Below is an example from *Version Control with Git, 2nd Edition* by
Jon Loeliger and Matthew McCullough that has proven useful to others.

```
git config --global alias.show-graph \
    'log --graph --abbrev-commit --pretty=oneline'
```

Once you have run the above command, git will actually do `git log
--graph --abbrev-commit --pretty=oneline` whenever you type `git
show-graph`.

Since the alias is a shortcut for another git subcommand, you can also
give it any other options accepted by the subcommand.  For example, if
you always want to sign-off on your commits for Evergreen, since this
is the community policy for accepting code submissions via commit, you
might want to add the following alias to your Evergreen and OpenSRF
repositories:

    git config alias.egcommit 'commit -s'

You can now use this just like the regular commit subcommand.  All of
the following will still work:

```
git egcommit -a
git egcommit {filename}
```
