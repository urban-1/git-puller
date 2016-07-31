#!/bin/bash

#
# Git puller: Read config files (one for each repo) and syncronize it with
# its remote master
#

shopt -s extglob

# --- CONFIGURATION ---
# 
# General configuration for puller utility:
#

# Mailer
MAILER=/usr/bin/sendmail

# False to stop sending emails
SEND_UPDATE_MAILS=1

# False to stop sending ERROR mails
SEND_ERROR_MAILS=1

DATE_FORMAT="%d/%m/%Y %H:%M:%S"

LOG_LEVEL=10

KEY_FILE=~/.ssh/id_rsa

export GIT_SSH_COMMAND="ssh -i $KEY_FILE -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

#
# --- End of CONFIGURATION ---
#



# Generic config folder
config="/etc/git-puller"

declare -A repo_errors

function prt(){
    lvl="???"
    
    case $1 in
        10) lvl="DEBUG";;
        20) lvl="INFO";;
        30) lvl="WARN";;
        40) lvl="ERROR";;
        50) lvl="CRIT";;
    esac
    
    if [ $LOG_LEVEL -le $1 ]; then
        printf "%19s %6s %s\n" "`date +"%d/%m/%Y %H:%M:%S"`" $lvl "$2" 1>&2
    fi
    
}

function debug(){ prt 10 "$1"; }
function info() { prt 20 "$1"; }
function warn() { prt 30 "$1"; }
function error(){ prt 40 "$1"; }

function usage(){
    echo ""
    echo "Usage: $0 [config]"
    echo ""
}

function read_config(){
    # set the actual path name of your (DOS or Unix) config file
    configfile=$1
    
    while IFS='= ' read lhs rhs
    do
        if [[ ! $lhs =~ ^\ *# && -n $lhs ]]; then
            rhs="${rhs%%\#*}"    # Del in line right comments
            rhs="${rhs%%*( )}"   # Del trailing spaces
            rhs="${rhs%\"*}"     # Del opening string quotes 
            rhs="${rhs#\"*}"     # Del closing string quotes 
            
            # Declare (global)
            cfg[$lhs]=$rhs
            debug "   - Declaring $lhs=$rhs"
        fi
    done < <(tr -d '\r' < $configfile)
}

function clean_repo_vars(){
    for i in "${repo_vars[@]}"
    do
        unset "$i"
    done
}

function git_current_brach(){
    branch_name="$(git symbolic-ref HEAD 2>/dev/null)" || \
        branch_name="(detached)"     # detached HEAD
        
    echo ${branch_name##refs/heads/}
    
}

function git_distance(){
    status=`cd "$1" && git rev-list --left-right $2...$3 2>/dev/null`
    LEFT_AHEAD=$(echo -e "$status" | grep -c '^<')
    RIGHT_AHEAD=$(echo -e "$status" | grep -c '^>')
    echo "$LEFT_AHEAD,$RIGHT_AHEAD"
}

function git_untracked() {
    echo "$(cd $1 && git status --porcelain 2>/dev/null| grep "^??" | wc -l)"
}

function git_uncommited() {
    echo "$(cd $1 && git status --porcelain 2>/dev/null| egrep "^(M| M)" | wc -l)"
}


# Files already added (modified and new)
function git_added() {
    echo "$(cd $1 && git status --porcelain 2>/dev/null| egrep "^(M|A)" | wc -l)"
}

function git_new() {
    echo "$(cd $1 && git status --porcelain 2>/dev/null| grep "^A" | wc -l)"
}

function handle_repo(){
    # get $1 as array
    
    # Cleanup and declare local
    declare -A -l cfg
    read_config "$1"
    repoName="$1"
    
    # Shorthand for cd ... && 
    function cdgit() { cd ${cfg[LOCAL_TREE]}; }
    
    if [[ -z "${cfg[LOCAL_BRANCH]// }" ]]; then
        warn "Local branch not provided - using default (master)"
        cfg[LOCAL_BRANCH]="master"
    fi
    
    if [[ -z "${cfg[REMOTE_BRANCH]// }" ]]; then
        warn "Remote branch not provided - using default (master)"
        cfg[REMOTE_BRANCH]="master"
    fi
    
    
    if [[ -z "${cfg[REMOTE_NAME]// }" ]]; then
        warn "Remote name not provided - using default (origin)"
        cfg[REMOTE_NAME]="origin"
    fi
    
    # Check and create?
    if [ ! -d "${cfg[LOCAL_TREE]}" ]; then
        if  [ "${cfg[REMOTE_URI]}" == "" ]; then
            tmpmsg="Remote is not set and local does not exist - cannot clone"
            repo_errors["$repoName"]=$tmpmsg
            error "$tmpmsg"
            return
        fi
    
        info "Cloning remote ${cfg[REMOTE_URI]} to ${cfg[LOCAL_TREE]}"
        git clone ${cfg[REMOTE_URI]} ${cfg[LOCAL_TREE]}
    fi
    
    # ensure git
    if [ ! -d "${cfg[LOCAL_TREE]}/.git" ]; then
        error "Folder exists (${cfg[LOCAL_TREE]}) but does not appear to be a git repo"
        return
    fi
    
    # Check for new files
    untracked=`git_untracked "${cfg[LOCAL_TREE]}"`
    if [ $untracked -ne 0 ]; then
        if [ ${cfg[ALLOW_UNTRACKED]} -ne 1 ]; then
            error "Config does not allow untracked"
            return
        else
            warn "Ignoring $untracked untracked files"
        fi
    fi
    
    # Check uncommited (added or not) and new added files
    uncom=`git_uncommited "${cfg[LOCAL_TREE]}"`
    added=`git_new "${cfg[LOCAL_TREE]}"`
    dirty=$(($added+$uncom))
    if [ $dirty -ne 0 ]; then
        if [ ${cfg[ALLOW_DIRTY]} -ne 1 ]; then
            error "Your local tree is DIRTY with $uncom uncommited changes and $added new files - and this is not allowed..."
            return
        fi
        warn "Dirty local tree with $uncom uncommited changes and $added new files"
        (cdgit && git stash)
        warn "Changes stashed"
        
    fi
    
    # Get current branch
    oldBranch=""
    branch=$(cdgit && git_current_brach)
    info "(1st) Your local branch is '$branch'"
    
    if [ "$branch" == "(detached)" ]; then
        warn "Detached head has been detected"
        if [ ${cfg[ALLOW_DETACHED_HEAD]} -ne 1 ]; then
            error "Detached head is not allowed... exiting"
            return
        fi
        
        # Fix detached
        warn "Fixing HEAD"
        oldBranch=$(cdgit && git rev-parse --verify HEAD)
        (cdgit && git checkout ${cfg[LOCAL_BRANCH]})
        branch=$(cdgit && git_current_brach)
        info "(2nd) Your local branch is '$branch'"
    fi
    
    if [ "$branch" != "${cfg[LOCAL_BRANCH]}" ]; then
        warn "Local branch mismatch - different one checked-out"
        if [ ${cfg[ALLOW_DIFFERENT_BRANCH]} -ne 1 ]; then
            error "Different branch is not allowed... exiting"
            return
        fi
        
        # Fix detached
        warn "Changing branch"
        oldBranch=$branch
        (cdgit && git checkout ${cfg[LOCAL_BRANCH]})
        branch=$(cdgit && git_current_brach)
        info "(2nd) Your local branch is '$branch'"
    fi
    
    #
    # If here, we are all good to go! So update
    #
    (cdgit && git fetch ${cfg[REMOTE_NAME]})
    (cdgit && git fetch ${cfg[REMOTE_NAME]} --tags)
    
    # Get changes
    remoteFull="${cfg[REMOTE_NAME]}/${cfg[REMOTE_BRANCH]}"
    IFS=',' read -r ahead behind <<<`git_distance ${cfg[LOCAL_TREE]} HEAD "$remoteFull"`
    info "Your current HEAD is $ahead ahead and $behind behind the remote $remoteFull"
    
    #
    # Check ahead
    #
    if [ $ahead -gt 0 ]; then
        
        if [ ${cfg[ALLOW_AHEAD]} -ne 1 ]; then
            error "Your local branch is ahead and this is not allowed inconfig"
            return
        fi
        
        if [ "${cfg[AHEAD_POLICY]}" == "push" ]; then
            warn "A git PUSH will happend at the end to update the remote"
        else
            # EXPERIMENTAL: There are 2 cases... 
            #   - 1. We are indded ahead due to commits
            #   - 2. Someone rolled back the remote!
            
            error "Someone rolled back the remote branch... we are following"
            dt=`date +"%Y%m%d%H%M%S"`
            info "   - Creating branch: rollback-$dt"
            (cdgit && git branch "rollback-$dt")
            (cdgit && git reset --hard "$remoteFull")
            return
        fi
    fi
    
    #
    # Get current location
    #
    currentHash=$(cdgit && git rev-parse --verify HEAD)
    info "Your hash atm is: $currentHash"
    
    (cdgit && git merge "$remoteFull")
    rc=$?
    if [ $rc -ne 0 ]; then
        warn "Merging failed ... reseting HARD to previous HASH"
        (cdgit && git merge --abort)
        # The following is the same!
        # (cdgit && git reset --hard $currentHash)
        return
    fi
    
    
    #
    # Check local and remote HEADS match
    #
    currentHash=$(cdgit && git rev-parse --verify HEAD)
    currentRemote=$(cdgit && git rev-parse --verify $remoteFull)
    if [ "$currentHash" != "$currentRemote" ]; then
        warn "We are ahead! Pushing to remote"
        (cdgit && git push ${cfg[REMOTE_NAME]} ${cfg[REMOTE_BRANCH]})
    fi
    
    if [ "$oldBranch" != "" ]; then
        info "Checking back to $oldBranch"
        (cdgit && git checkout "$oldBranch")
    fi
    
}

while getopts ":c:" opt; do
    case $opt in
        c)
            config=$OPTARG 
        ;;
        h)
            usage
        ;;
        \?)  usage ;;
    esac
done

shift $(($OPTIND - 1))

for c in $config/*
do
        info "Handing repo config '$c'"
        handle_repo "$c"
        
done

exit 0


