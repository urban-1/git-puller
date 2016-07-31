#!/bin/bash

TMP=/tmp
RL=$TMP/tmp-repo
RR=$TMP/tmp-remote

# Clean
rm -rf $RR 2> /dev/null
rm -rf $RL 2> /dev/null


mkdir -p $RR
(cd $RR && git init)
(cd $RR && echo "TEST" > f1 && git add ./f1 && git commit -a -m "Initial Commit")
(cd $RR && echo "TEST2" > f2 && git add ./f2 && git commit -a -m "Second Commit")
(cd $RR && echo "TEST3" > f3 && git add ./f3 && git commit -a -m "Third Commit")
THIRD_REMOTE=`(cd $RR && git rev-parse --verify HEAD)`


#
# Basic tests
#

echo -e "\n\n 1. --- TEST CREATE ------------------------"
# 1. Test creation
./puller.sh -e -c ./test


echo -e "\n\n 2. --- DETACHED HEAD DENY -----------------"
(cd $RL && git checkout HEAD^1)
./puller.sh -e -c ./test


echo -e "\n\n 3. --- DETACHED HEAD ALLOW ----------------"
sed -i 's/ALLOW_DETACHED_HEAD=0/ALLOW_DETACHED_HEAD=1/g' ./test/tmp-repo.conf
./puller.sh -e -c ./test
sed -i 's/ALLOW_DETACHED_HEAD=1/ALLOW_DETACHED_HEAD=0/g' ./test/tmp-repo.conf
(cd $RL && git checkout master)


echo -e "\n\n 4. --- UNTRACKED ALLOW --------------------------"
(cd $RL && touch ./newFile)
./puller.sh -e -c ./test


echo -e "\n\n 5. --- UNTRACKED DENY --------------------------"
sed -i 's/ALLOW_UNTRACKED=1/ALLOW_UNTRACKED=0/g' ./test/tmp-repo.conf
./puller.sh -e -c ./test
sed -i 's/ALLOW_UNTRACKED=0/ALLOW_UNTRACKED=1/g' ./test/tmp-repo.conf


echo -e "\n\n 6. --- DIRTY DENY (ADDED) --------------------------"
(cd $RL && git add ./newFile)
./puller.sh -e -c ./test


echo -e "\n\n 7. --- DIRTY DENY (MOD+ADDED) --------------------------"
(cd $RL && echo "2" > ./f2)
./puller.sh -e -c ./test


echo -e "\n\n 8. --- DIRTY ALLOW (MOD+ADDED) --------------------------"
sed -i 's/ALLOW_DIRTY=0/ALLOW_DIRTY=1/g' ./test/tmp-repo.conf
./puller.sh -e -c ./test
sed -i 's/ALLOW_DIRTY=1/ALLOW_DIRTY=0/g' ./test/tmp-repo.conf


echo -e "\n\n 9. --- NEW FILES ON REMOTE --------------------------"
(cd $RR && echo "TEST4" > f4 && git add ./f4 && git commit -a -m "4th Commit")
./puller.sh -e -c ./test


echo -e "\n\n 10. --- WE ARE AHEAD (PUSH) -------------------------"
sed -i 's/AHEAD_POLICY="rollback"/AHEAD_POLICY="push"/g' ./test/tmp-repo.conf
(cd $RL && echo "TEST5" > f5 && git add ./f5 && git commit -a -m "5th Commit - slave")
# ... checkout another branch to allow push!
(cd $RR && git checkout -b old-master)
./puller.sh -e -c ./test
(cd $RR && git checkout master)
(cd $RR && git branch -d old-master)
sed -i 's/AHEAD_POLICY="push"/AHEAD_POLICY="rollback"/g' ./test/tmp-repo.conf


echo -e "\n\n 11. --- WE ARE AHEAD (REMOTE ROLLBACK) -------------"
# ... checkout another branch to allow rollback
(cd $RR && git checkout -b old-master)
(cd $RR && git branch -d master)
(cd $RR && git checkout -b master $THIRD_REMOTE)
./puller.sh -e -c ./test


#
# The following always last... 
#
echo -e "\n\n 100. --- FAILED MERGE --------------------------------"
sed -i 's/AHEAD_POLICY="rollback"/AHEAD_POLICY="push"/g' ./test/tmp-repo.conf
(cd $RR && echo "TEST100" > f15 && git add ./f15 && git commit -a -m "100th Commit - master")
(cd $RL && echo "TEST100.1" > f15 && git add ./f15 && git commit -a -m "100th Commit - slave")
./puller.sh -e -c ./test
sed -i 's/AHEAD_POLICY="push"/AHEAD_POLICY="rollback"/g' ./test/tmp-repo.conf

exit 0

