package MySQL::Replication;

use strict;
use warnings;

our $VERSION = '0.01';

1;

__END__

=head1 NAME

MySQL::Replication - Decentralised, peer-to-peer, multi-master MySQL replication

=head1 DESCRIPTION

=head2 What is MySQL::Replication

MySQL::Replication is a replacement for MySQL's built-in replication. The
reason for this module is that there are a number of issues with MySQL's
built-in replication:

=over

=item *

You Can't Have Multiple Masters

By design, slaves can only replicate from a single master. Emulating
multi-master replication is possible, but this creates even further issues:

=over

=item *

There Is A Possibility Of Infinite Replication Loops

Emulating multi-master replication with a ring topology depends on having all
masters in the ring being available. If a master dies while still having its
queries circulating around the ring, the queries won't be filtered out and so
an infinite replication loop occurs.

Although a ring topology can be created with MySQL::Replication, there is no
ring replication. This is because clients do not binlog when executing
replicated queries. So when a server is serving out local binlogs, there is no
risk of serving non-locally generated queries and thus no risk of infinite
replication loops.  

=item *

Time Is Wasted By Time Slicing

Emulating multi-master replication by time slicing wastes time when the
currently connected master doesn't have anything to replicate.

Since MySQL::Replication achieves multi-master replication by running multiple
instances of the client in parallel, there is no time slicing via a timer and
thus no time wasted by time slicing. Note that time slicing still happens via
the operating system's process scheduler however since socket reads in the
client are blocking, there is no time wasted by polling.

=back

=item *

Queries May Get Replayed After A Slave Crash

A slave's master position is recorded in the C<relay-log.info> file however
writes to the InnoDB tablespace and C<relay-log.info> are not atomically
synced to disk. If a slave dies and comes back online, files may be in an
inconsistent state. If the InnoDB tablespace was flushed to disk before the
crash but C<relay-log.info> wasn't, the slave will restart replication from a
stale position and so will replay queries.

MySQL::Replication clients store their server positions inside the InnoDB
tablespace (i.e. the C<Replication.SourcePosition> table by default). Since
updates are done within the same transaction as replicated queries are
executed in, writes are atomic. If a slave dies and comes back online, we will
still be in a consistent state since either the transaction was committed or
it will be rolled back.

=item *

Moving Slaves To Different Masters Is Hard

A slave's master position is relative to the directly connected master's
binlogs. Given a multi-layer replication topology e.g. a tree topology, a
slave's master position is still relative to the directly connected master's
binlogs and not relative to the root master's binlogs. If a master in a middle
layer dies, moving its slaves to a different master is non-trivial since they
will all need their master positions translated to the new master's binlogs.

MySQL::Replication always deals with canonical binlog positions. In a
multi-layer replication topology e.g. a tree topology, positions are always
relative to the root server's binlogs. If a relay in a middle layer dies,
moving its clients to a different relay is a simple configuration item change
since no translation is needed.

=back

=head2 How Does MySQL::Replication Work

A MySQL::Replication replication topology is made up of:

=over

=item *

MySQL::Replication servers

=item *

MySQL::Replication clients

=item *

MySQL::Replication relays

=back

=head3 MySQL::Replication Servers

A MySQL master runs a MySQL::Replication server, which serves queries from
its local binlogs e.g.: 

  db1.example.com:~$ MySQLReplicationServer.pl --binlog db1:/var/lib/mysql/binlogs/mysql-bin.index

The server running on C<db1.example.com> will serve queries from the binlogs
listed in C<mysql-bin.index>.

See L<MySQLReplicationServer.pl> for more information on servers.

=head3 MySQL::Replication Clients

A MySQL slave runs the MySQL::Replication client e.g.:

  db2.example.com:~$ MySQLReplicationClient.pl --srchost db1.example.com --srcbinlog db1

The client running on C<db2.example.com> will:

=over

=item *

Get the server position for C<db1.example.com> from the local database

=item *

Connect to the server running on C<db1.example.com>

=item *

Request queries, starting from its server position

=item *

Read the query response from the server

=item *

Execute the query on the local database

=item *

Update the server position in the local database

=item *

Wait for the next query response

=back

  +-----------------+       +-----------------+
  | db1.example.com | ----> | db2.example.com |
  +-----------------+       +-----------------+

To replicate from multiple masters, run multiple instances of the client e.g.:

  db2.example.com:~$ MySQLReplicationClient.pl --srchost db1.example.com --srcbinlog db1
  db2.example.com:~$ MySQLReplicationClient.pl --srchost db3.example.com --srcbinlog db3

  +-----------------+       +-----------------+       +-----------------+
  | db1.example.com | ----> | db2.example.com | <---- | db3.example.com |
  +-----------------+       +-----------------+       +-----------------+

Note that there is no restriction on where the client and server run. e.g.
having all databases replication to and from each other is possible:

  +-----------------+       +-----------------+       +-----------------+
  | db1.example.com | <---> | db2.example.com | <---> | db3.example.com |
  +-----------------+       +-----------------+       +-----------------+
           ^                                                   ^
           |                                                   |
           +---------------------------------------------------+

See L<MySQLReplicationClient.pl> for more information on clients.

=head3 MySQL::Replication Relays

A MySQL::Replication relay acts as a proxy cache. In a multi-layer replication
topology, middle layers run a MySQL::Replication relay e.g.:

  relay.example.com:~$ MySQLReplicationRelay.pl

The relay running on C<relay.example.com> will:

=over

=item *

Accept requests from connecting clients

=item *

If the relay can fulfill the request from its cache, it will serve them to the
client

=item *

If the relay cannot fulfill the request from its cache, it will:

=over

=item *

Connect directly to the server, or if specified, the next relay

=item *

Relay the request to the next layer

=item *

Read the query response

=item *

Cache the query response for future requests

=item *

Send the query response to the client

=item *

Wait for the next query response

=back

=back

  +-----------------+       +-------------------+       +-----------------+
  | db1.example.com | ----> | relay.example.com | ----> | db2.example.com |
  +-----------------+       +-------------------+       +-----------------+

By using relays:

=over

=item *

Bandwidth is saved since multiple clients in one data center need only connect
to the local relay, while the relay goes over the WAN to fulfill requests

=item *

Load is saved on the server since the number of connecting clients is reduced

=back

Note that there is no restriction on the number of layers of relays e.g. a
tree of relays is possible:

  +-----------------+
  | db2.example.com | <---------------+
  +-----------------+                 |
                                      |
  +-----------------+       +--------------------+       
  | db3.example.com | <---- | relay2.example.com | <----------------+ 
  +-----------------+       +--------------------+                  | 
                                                                    |
                                                         +--------------------+       +-----------------+
                                                         | relay1.example.com | <---- | db1.example.com |
                                                         +--------------------+       +-----------------+
                                                                    |
  +-----------------+       +--------------------+                  |
  | db4.example.com | <---- | relay3.example.com | <----------------+ 
  +-----------------+       +--------------------+       
                                      |
  +-----------------+                 |
  | db5.example.com | <---------------+
  +-----------------+ 

See L<MySQLReplicationRelay.pl> for more information on relays.

=head2 FAQs

=head3 What Happens If There Is A Race Condition On A Record

e.g. An insert to the C<users> table occurs on two seperate databases at the
same time for the C<username> 'alfie'. The problem here is that C<username> is
the primary key. Since the inserts happened at the same time, both inserts
succeeded. It is only when they replicate will a primary key constraint fail. 
If this happens, replication will stop and manual intervention is necessary.

The only way to prevent this is to avoid the race in the first place:

=over

=item *

Use an external arbiter to protect access to shared resources

e.g. before inserting into the C<users> table, each program performing the
insert contacts the arbiter and request the inserting of 'alfie'. The first
request is granted the insert while the others fail.

=item *

Shard your data so that race conditions cannot occur

e.g. the C<users> table is sharded based on the first letter of the usename.
Inserts for 'alfie' only happen on the database with write access to the 'a'
records.

=item *

Don't use C<AUTO_INCREMENT> keys, use UUIDs instead

Not useful in the C<users> example, but for tables where C<AUTO_INCREMENT> ids
are used, switch to UUIDs to avoid clashes.

=back

=head1 BUGS

=over

=item *

The relay is still in development and have not been released yet

=item *

Communication over the wire is in plain text. Only use MySQL::Replication over
a secure channel (e.g. stunnel, IPSec etc)

=item *

Row-based replication is not supported yet

=item *

LOAD DATA events are not supported yet

=item *

Filtering on queries, tables and schemas are not supported yet

=back

=head1 SEE ALSO

=over

=item *

L<MySQLReplicationClient.pl>

=item *

L<MySQLReplicationServer.pl>

=item *

L<MySQLReplicationRelay.pl>

=item *

L<https://github.com/alfie/MySQL--Replication>

=back

=head1 AUTHOR

Alfie John, C<alfiej@opera.com>

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2011, Opera Software Australia Pty. Ltd.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

  * Redistributions of source code must retain the above copyright notice,
    this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright notice,
    this list of conditions and the following disclaimer in the documentation
    and/or other materials provided with the distribution.
  * Neither the name of the copyright holder nor the names of its contributors
    may be used to endorse or promote products derived from this software
    without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut
