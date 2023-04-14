# Using Git with Evergreen #

The Evergreen community has a [page on the dokuwiki
site](https://wiki.evergreen-ils.org/doku.php?id=dev:git) that
explains how the community uses git to manage the Evergreen, OpenSRF,
and other related projects' code.  If you want to share patches with
the community, this is a good place to start.

## Managing Overrides ##

Assuming that we have overrides for the whole consortium in the Apache
`eg_vhost.conf` file:

    PerlAddVar OILSWebTemplatePath "/openils/var/templates"
    PerlAddVar OILSWebTemplatePath "/openils/var/templates-bootstrap"
    PerlAddVar OILSWebTemplatePath "/openils/var/templates_cons"
    PerlAddVar OILSWebTemplatePath "/openils/var/templates-bootstrap_cons"

You could then have any number of `VirtualHost` that add overrides for
other members or groups of members, such as this example for the SYS1
system from the sample data set:

    <VirtualHost sys1.host.tld:443>
    ...
    PerlAddVar OILSWebTemplatePath "/openils/var/templates"
    PerlAddVar OILSWebTemplatePath "/openils/var/templates-bootstrap"
    PerlAddVar OILSWebTemplatePath "/openils/var/templates_sys1"
    PerlAddVar OILSWebTemplatePath "/openils/var/templates-bootstrap_sys1"
    ...
    </VirtualHost>

Create a branch for each set of override directories that you have.
Given the above examples, this would be a branch for `cons` and another
for `sys1`.  Edit the templates in their normal locations in the
respective branch to make the changes that you require.  Always edit
the templates in these branches.  Use these branches to keep up to
date with new releases, i.e. rebase, etc.

When it comes time to actually install or test your overrides, make a
new branch where the modified templates can be moved into their
override locations.  It makes sense to use this branch to do your
installation or upgrade of Evergreen, so you will eventually put all
of your other changes into this branch as well.

You can list your modified templates with the following two commands.


    git diff --name-only <custombranch> -- Open-ILS/src/templates | sed -e '/\/marc\//d'
    git diff --name-only <custombranch> -- Open-ILS/src/templates-bootstrap

Where `<custombranch>` is the branch with your customized templates.
The addition of the `sed` command on the first example stops any
customized MARC templates from showing up in the output.  It is assumed
that you don't want to put these in an override directory.

You can use those commands and dump the output into a file, and then
edit that list of files into a bunch of commands that you could run
via `bash` or `sh`.  For instance, assuming you have customized at
least the style.css.tt2 files for both the TTOPAC and Bootstrap
templates, which is a very common thing to do, you'll want to edit the
following lines:

    Open-ILS/src/templates/opac/css/style.css.tt2
    Open-ILS/src/templates-bootstrap/opac/css/style.css.tt2

so that they look like the following in your script:

    if [ ! -e Open-ILS/src/templates_cons/opac/css ]; then
        mkdir -p Open-ILS/src/templates_cons/opac/css
    fi
    git show <custombranch>:Open-ILS/src/templates/opac/css/style.css.tt2 \
    > Open-ILS/src/templates_cons/opac/css/style.css.tt2
    if [ ! -e Open-ILS/src/templates-bootstap_cons/opac/css ]; then
        mkdir -p Open-ILS/src/templates-bootstap_cons/opac/css
    fi
    git show <custombranch>:Open-ILS/src/templates-bootstap/opac/css/style.css.tt2 \
    > Open-ILS/src/templates-bootstap_cons/opac/css/style.css.tt2

You will want to add a similar set of lines for every modified
template file, and for every set of overrides you use.  The above
example assumes the `_cons` override from the previous Apache
configuration examples.  You will want to change the `_cons` to
whatever is appropriate for your situation.

Given that manually editing long lists of files is error prone, even
with the assistance of editor features, you could just run the
[overridinator script](Examples/overridinator) that the author has
prepared for this purpose.
