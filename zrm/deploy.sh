#!/bin/bash

code_base=$1
do_tarball=$2
tag=$3

if [[ -z $code_base ]]
then
	echo "Need a codebase!"
	exit 1
fi

if [[ -n $do_tarball ]]
then
  # Do stuff to make a tarball at tag X.
  if [[ -z $tag ]]
  then
    echo "Need a tag to make a tarball."
    exit 1
  fi
  prev_head=$(git branch | grep '^*' | awk '{print $2}')
  git stash
  git checkout $tag
  git log > CHANGELOG.git
  tar czvf zrm-innobackupex-$tag.tar.gz \
    plugins/socket-copy.palomino.pl \
    plugins/socket-server.palomino.pl \
    plugins/inno-snapshot.pl \
    examples/zrm_nsca.cfg \
    examples/example_nagios.cfg \
    examples/mysql-zrm.conf \
    examples/socket_server.conf \
    examples/zrm-palomino.xinetd \
    README CHANGELOG CHANGELOG.git
  rm CHANGELOG.git
  git checkout "$prev_head"
  git stash pop
  exit 0
fi

HOSTS="testdb1 testdb2"
for host in $HOSTS
do
	rsync -avP $code_base/ root@$host:/usr/share/mysql-zrm/plugins/
	ssh root@$host 'chown -R mysql:mysql /usr/share/mysql-zrm/plugins'
	ssh root@$host 'chown -R mysql:mysql /etc/mysql-zrm'
	ssh root@$host 'mkdir -p /mysqlbackups && chown -R mysql:mysql /mysqlbackups'
	ssh root@$host 'chown -R mysql:mysql /var/log/mysql-zrm'
done