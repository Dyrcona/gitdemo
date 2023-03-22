# What Is Git? #

Git is a distributed version control system.

## What Is a Version Control System? ##

A version control system (abbreviated as VCS) is a method of recording
and managing changes to data over time. Some examples of VCS include:

1. manually copying data files before editing them
2. an editor program making automatic backup copies of files before changing them on disk
3. a separate software package dedicated to managing changes made to a set of data files
4. turning on the "Track Changes" or "Record Changes" feature in an editor program
5. an audit table with audit triggers in a database

Each of the above methods has its advantages, disadvantages, and area
of applicability.  Numbers 1 through 3 are the most generally
applicable to a wide ranged of data, and they are listed in order from
least to most advantageous, at least in the author's opinion.  Numbers
4 and 5 are more narrowly applicable to specific software applications,
but are certainly worth including in this list.

Git is the third type in the list, and so are most of the other
software that we normally refer to as a version control system.

## What Does "Distributed" Mean? ##

When applied to a version control system, "distributed" means "not
centralized."

There are 3 methods of storing changes and sharing them with others
depending on the VCS method or software being used, *local*,
*centralized* (also known as client/server), and *distributed*.  The
local storage method stores the changes on a local hard drive or
network share, generally without the intervention of another program.
The centralized storage method has its main storage on a single,
centralized server that is accessible to many users and typically
requires a special program to access the data.  Distributed storage
allows the changes to be stored in a number of different locations
without the need for a central server, and without the inherent
limitations of local storage.

### Local ###

A VCS is local if there is no way to share change with other users on
a remote network without copying all of the necessary data and history
files.

Examples of local storage include:

* manual backup copies
* editor-derived backup copies
* some older VCS software, such as [rcs](https://www.gnu.org/software/rcs/) and [sccs](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/sccs.html)
* audit tables with audit triggers in a database
* the "Track Changes" feature of a word processor or similar editor

The "Track Changes" feature is perhaps unique in that the programs
that offer this feature usually track the changes inside the data file
itself, so it is possible to send all of the changes along with the
main data file to another user without much effort.  However, this
feature does have a tendency to increase the file size which makes it
more difficult to share such files with others.

### Centralized ###

A centralized VCS stores the files and tracks changes on a single
server and typically requires special software for access following
the client/server model.  Users will use the client software to run
commands to let the server and other users know that they are working
on certain files.  With these systems, only 1 user at a time can work
on a given file.

Examples of centralized VCS include [CVS (concurrent versions system)](https://www.nongnu.org/cvs/)
and [SVN (Subversion)](https://subversion.apache.org/).

### Distributed ###

A distributed version control system (DVCS) combines characteristics
of local and centralized VCS and extends the model with new features.
Each user works locally on their own copy of the code and then shares
the changes with others via remote servers.  Unlike in the centralized
model there can be multiple servers, and each copy (whether local or
remote) is not technically superior to any other, though they will
likely contain different changes based on the work that has been done
locally.

Examples of distributed version control systems include:

* [GNU Arch](https://www.gnu.org/software/gnu-arch/)
* [BitKeeper](http://www.bitkeeper.org/)
* [Breezy](https://www.breezy-vcs.org/)
* [Git](https://git-scm.com/)
* [Mercurial](https://www.mercurial-scm.org/)
* [Monotone](https://www.monotone.ca/)
