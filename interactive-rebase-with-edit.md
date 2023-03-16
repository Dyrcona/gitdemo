# Interactive Rebase Example

Here's an example of a somewhat complicated interactive rebase that I
did recently.  I had a custom branch based on the Evergreen `rel_3_10`
branch, with several backports and testing features, that I wanted to
rebase in order to refresh the code and to make some changes.  With
this example rebase, you are going to:

1. drop the custom database upgrade script
2. undo a change to `marc_export.in` in the base commit
3. fixup a bunch of later commits into the base commit
4. cherry-pick the latest `marc_export` features from the master branch

In a fresh clone of the gitdemo repository, run the following commands
to get the branches that you need.

```
git fetch origin local/custom_rel_3_10:local/custom_rel_3_10
git fetch git://git.evergreen-ils.org/Evergreen.git rel_3_10:evergreen/rel_3_10
git fetch git://git.evergreen-ils.org/Evergreen.git master:evergreen/master
```

Checkout a copy of the `local/custom_rel_3_10` branch to preserve the
original in case something goes horribly wrong.

```
git checkout -b local/custom_rel_3_10-rebase local/custom_rel_3_10
```

Save the commit message for afc72b28aaed9fe2f20de6419de32c83d5044aa7 to be edited and reused.

```
commit afc72b28aaed9fe2f20de6419de32c83d5044aa7
Author: Jason Stephenson <jason@sigio.com>
Date:   Wed Dec 7 14:52:57 2022 -0500

    Forward Port CW MARS Legacy Customization
    
    This commit adds most CW MARS customization for Evergreen 3.7.3 to
    rel_3_10.  Some customization that would no longer apply has been
    dropped.  If we need to bring it back, it can be fished out from git.
    
    CWMARS Bootstrap Customization
    
    Add color modification for Bootstrap implemented by John Amundson.
    
    Replace green cart with blue cart image
    
    Use CW MARS Logo
    
    Move main logo below carousels
    
    Set Code to use library logos when appropriate
    
    Customize Bootstrap OPAC topnav links
    
    Customize Bootstrap OPAC footer links
    
    Use home logo's natural size so it looks normal.
    
    Adjust topnav logo margins
    
    Move topnav logo out of header wrap
    
    Replace top nav logo with horizontal version
    
    Move CW MARS home link to the footer
    
    Reduce size of title on Bootstrap OPAC record summary
    
    Replace the class attribute of the h1 name element with a style
    attribute to set "font-size: 1.8em;" to match PINES.
    
    Expand awards by default
    
    Add our curbside pickup language to bootstrap OPAC
    
    Login Modal Changes for Bootstrap
    
    Move Awards, Reviews, & Suggested Reads to head of the class
    
    Update Bootstrap main refund policy
    
    Apply login customization to login/form.tt2
    
    Customize Bootstrap Patron registration page
    
    Customize Advanced Search Filters for Bootstrap
    
    Display uri filtered_note in record summary
    
    More CSS color updates
    
    Use our primary color for confirm buttones and card headers in the rdetails
    extras div.
    
    Remove Advanced Search from staff client splash page
    
    Remove code to reveal the pivot options in the reporter
    
    LP1940662: Add a --pipe option to marc_export
    
    Run GCC patron purge in June as well as December
    
    Remove A/T runners from crontab.util2 for unused granularities
    
    Add OCLC, Music Number, & Government Document Number searches to the
    Bootstrap OPAC search.
    
    Add our custom OCLC, Music Number, and Government Document Number
    searches to the Angular staff catalog's Numeric (Identifier) Search.
    
    Our custom search types for Uniform Title and Publisher were not
    ported to the Bootstrap or Angular Staff Catalogs.  This commit adds
    them to both.
    
    Force the default sort to poprel in the Angular Staff Catalog
    
    Make a nasty hack to set the sort to poprel in the search context when
    it is reset.
    
    This should be removed if the issue is ever fixed properly by the
    community.
    
    Fix Bootstrap self-registation date format example
    
    Run EDS export for AIC and MWCC weekly instead of monthly
    
    Enable HTTPS rewrite for all URLs
    
    Add OCLC Cloud IP addresses to marc_stream_importer configuration
```

Now that you have saved at least the commit message body to a file,
you can start the interactive rebase:


```
git rebase -i evergreen/rel_3_10
```

Your text editor should open with a window full of text that looks like the text below.


```
pick a58d030247 Add CW MARS Custom 3.7.3 to 3.10.0 DB Upgrade
pick afc72b28aa Forward Port CW MARS Legacy Customization
pick 227a6d2a64 Add Training Server Message
pick 202d3c317d Update opensrf.xml.example
pick 6551c1f034 Fix OSRFTranslatorCacheServer settings
pick 098a26af6b Add Huntington to custom host files
pick 013509c8c4 Use default small logo for Huntington
pick 785d313026 LP1948693 Migrate from NgbTabset to ngbNav
pick 6d72abf502 lp1959010 toward Staff View tab
pick 3ce4da0c83 lp1959010 CSS and layout tweaks
pick 9b90eb2342 lp1959010 toward Staff View tab
pick 83be4ca63f lp1959010 have the staff display component check search context for the active search OU
pick 6163ada65d lp1959010 release notes
pick 2c7c42ae05 LP1980978: Improve SIP2 Patron Status Field
pick ee86116457 Turn pager off in CW MARS DB Upgrade Script
pick 326e99016d Revert "LP#1919500 - Tweak to Checkout Staff display"
pick 37eae2e9e7 Revert "LP#1919500 - Add Checkout Workstation and Checkout Staff to Item Status -> Circ History List"
pick 2fc11e1a2c Add 1355 to custom upgrade
pick ee51f94d0c Remove Options to Change Preferred Language in OPAC Preferences
pick c7836cedff Remove ability to set preferred language in patron reistration/edit
pick 673f75ca63 Remove "Pref Language" row from patron summary
pick 458e14f341 Add Becket and Chester
pick d896301df4 Rename CWMARS Custom DB Upgrade
```

Edit the rebase commands so that they look like this:


```
d a58d030247 Add CW MARS Custom 3.7.3 to 3.10.0 DB Upgrade
e afc72b28aa Forward Port CW MARS Legacy Customization
f 202d3c317d Update opensrf.xml.example
f 6551c1f034 Fix OSRFTranslatorCacheServer settings
f 098a26af6b Add Huntington to custom host files
f 013509c8c4 Use default small logo for Huntington
f 458e14f341 Add Becket and Chester
pick 227a6d2a64 Add Training Server Message
pick 785d313026 LP1948693 Migrate from NgbTabset to ngbNav
pick 6d72abf502 lp1959010 toward Staff View tab
pick 3ce4da0c83 lp1959010 CSS and layout tweaks
pick 9b90eb2342 lp1959010 toward Staff View tab
pick 83be4ca63f lp1959010 have the staff display component check search context for the active search OU
pick 6163ada65d lp1959010 release notes
pick 2c7c42ae05 LP1980978: Improve SIP2 Patron Status Field
d ee86116457 Turn pager off in CW MARS DB Upgrade Script
pick 326e99016d Revert "LP#1919500 - Tweak to Checkout Staff display"
pick 37eae2e9e7 Revert "LP#1919500 - Add Checkout Workstation and Checkout Staff to Item Status -> Circ History List"
d 2fc11e1a2c Add 1355 to custom upgrade
pick ee51f94d0c Remove Options to Change Preferred Language in OPAC Preferences
pick c7836cedff Remove ability to set preferred language in patron reistration/edit
pick 673f75ca63 Remove "Pref Language" row from patron summary
d d896301df4 Rename CWMARS Custom DB Upgrade
p 029c6c855b62e667e77cecc61226e864826ecd62
p 6cb814b9940efed81fe33b0a3df20780ec623d98
p eda46923facdd678fdd45661009ef6073855db84
```

After you save the changes and close your editor, something like the
folowing text will show on your screen.

<pre>
Stopped at afc72b28aa...  Forward Port CW MARS Legacy Customization
You can amend the commit now, with

  git commit --amend 

Once you are satisfied with your changes, run

  git rebase --continue
</pre>

At this point, you will run the commands below in order to:

1. Reset the commit pointer to the previous commit.  This loses the commit message and unstages the changed files so that you can make changes.
2. Overwrite our changes to the `marc_export.in` file by checking out the file as it existed in the now current commit.
3. Add all of the changed files to commited. This step is necessary because of the previous reset.
4. Commit the changed files.

```
git reset HEAD^
git checkout HEAD -- Open-ILS/src/support-scripts/marc_export.in
git add .
git commit --date="Wed Dec 7 14:52:57 2022 -0500"
```

When your editor opens with a blank screen for a commit message, you
want to paste in the previous message, but remove the line that reads
"LP1940662: Add a --pipe option to marc_export" as well as the line
above or below it.  Note that you also used the `--date` option to set
the commit date back to the original.  This is purely optional and
depends on how much of a stickler you are regarding history, dates,
and order.

Once you save the changes and close your editor, the commit will be
done, but the rebase is not finished.  Typing the following command
will allow it to complete.  It should finish without incident unless
something has drastically changed in the `rel_3_10` branch since I
last did a test run of this procedure.


```
git rebase --continue
```
