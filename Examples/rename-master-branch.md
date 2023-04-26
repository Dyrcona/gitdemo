# Rename Master Branch #

    git branch --move master main
    git push origin main
    git push origin --delete master

You can do this on GitHub via the GUI.

The following will update your local repository:

    git fetch --all
    git checkout -b main origin/main
    git branch -D master
