# 002_pack_table.t
# Copyright (C) 2013 PalominoDB, Inc.
# 
# You may contact the maintainers at eng@palominodb.com.
# 
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use strict;
use warnings FATAL => 'all';
use Test::More tests => 9;
use TestDB;
use DSN;
use Carp;

BEGIN {
  require_ok('src/pdb-packer');
  my $tdb = TestDB->new();
  $tdb->clean_db();
  $tdb->use('pdb_packer');
  for((1...4)) {
    my $eng = ($_ % 2 ? 'myisam' : 'innodb');
    $tdb->dbh()->do(qq|
      CREATE TABLE prfx_$_ (
        `id` INTEGER PRIMARY KEY AUTO_INCREMENT,
        `name` VARCHAR(60) NOT NULL
      ) Engine=$eng;
      |);
  }
}

my $ssh_user = $ENV{'LOGNAME'};
my $ssh_key  = $ENV{'TEST_SSH_KEY'} || $ENV{'HOME'} . '/.ssh/id_rsa';

my $tdb = TestDB->new();
my $dsn1 = DSNParser->default()->parse($tdb->dsn() .
  ",D=pdb_packer,t=prfx_1,sU=$ssh_user,sK=$ssh_key");
my $dsn2 = DSNParser->default()->parse($tdb->dsn() .
  ",D=pdb_packer,t=prfx_2,sU=$ssh_user,sK=$ssh_key");

my $dsn3 = DSNParser->default()->parse($tdb->dsn() .
  ",D=pdb_packer,t=prfx_5,sU=$ssh_user,sK=$ssh_key");

my $dsn4 = DSNParser->default()->parse($tdb->dsn() .
  ",u=nosuper,p=superpw,D=pdb_packer,t=prfx_4,sU=$ssh_user,sK=$ssh_key");

is_deeply(pdb_packer::pack_table($tdb->datadir(), $dsn1), [ undef, undef ], 'packs myisam table');
is($tdb->dbh()->selectrow_arrayref("SHOW TABLE STATUS FROM `pdb_packer` LIKE 'prfx_1'")->[3],
  'Compressed', 'mysql agrees about the packing');
is_deeply(pdb_packer::pack_table($tdb->datadir(), $dsn1),
  [
    $dsn1->get('t') .' is already compressed.',
    0
  ],
  'already packed table');

is_deeply(pdb_packer::pack_table($tdb->datadir(), $dsn2), [ undef, undef ], 'converts and packs innodb table');
is($tdb->dbh()->selectrow_arrayref("SHOW TABLE STATUS FROM `pdb_packer` LIKE 'prfx_2'")->[1],
  'MyISAM', 'mysql agrees about the conversion');
is($tdb->dbh()->selectrow_arrayref("SHOW TABLE STATUS FROM `pdb_packer` LIKE 'prfx_2'")->[3],
  'Compressed', 'mysql agrees about the packing');

eval { pdb_packer::pack_table($tdb->datadir(), $dsn3); };
like($@, qr/Table .* does not exist/, 'error on missing table');

eval { pdb_packer::pack_table($tdb->datadir(), $dsn4); };
like($@, qr/DBD::mysql::db do failed: Access denied; you need the SUPER privilege for this operation/, 'catch exception with missing privileges')
