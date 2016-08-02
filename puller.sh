#!/bin/bash

#
# Git puller: Read config files (one for each repo) and syncronize it with
# its remote master
#

shopt -s extglob

# Source utility config
DIRNAME=$(readlink -f $(dirname $0))
. $DIRNAME/puller-config.sh


# Support custom keys for git
export GIT_SSH_COMMAND="ssh -i $KEY_FILE -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

# Generic config folder
config="/etc/git-puller"

declare -A repo_errors
declare -A repo_warnings

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
        printf "%19s %6s %s\n" "`date +"$DATE_FORMAT"`" $lvl "$2" 1>&2
    fi
    
}

function debug(){ prt 10 "$1"; }
function info() { prt 20 "$1"; }
function warn() { prt 30 "$1"; }
function error(){ prt 42 "$1"; }

function usage(){
    echo ""
    echo "Usage: $0 [options] -c <config>"
    echo ""
    echo " Options:"
    echo "       -e    Do not send emails (disables mailer if configured)"
    echo "       -l    Message level (10=DEBUG, INFO=20, WARN=30 and ERROR=42 :))"
    echo ""
}

function read_config(){
    # set the actual path name of your (DOS or Unix) config file
    local configfile
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
            # debug "   - Declaring cfg[$lhs]=$rhs"
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

# Repo error, log and store
# indexed by repoName ($1)
function rerror(){
    if [ "${repo_errors[$1]}" != "" ]; then
        repo_errors[$1]="${repo_errors[$1]}|"
    fi
    repo_errors[$1]="${repo_errors[$1]}$2"
    error "$2"
}

# Repo warning, log and store
# indexed by repoName ($1)
function rwarn(){
    if [ "${repo_warnings[$1]}" != "" ]; then
        repo_warnings[$1]="${repo_warnings[$1]}|"
    fi
    repo_warnings[$1]="${repo_warnings[$1]}$2"
    warn "$2"
}

function errors_to_bullet(){
    repoName=$1
    
    OIFS=$IFS
    ret=""
    if [ "${repo_errors[$repoName]}" != "" ]; then
        ret="The following error(s) occured:\n"
        IFS='|' 
        for e in ${repo_errors[$repoName]}
        do
            ret="$ret  - $e\n"
        done
        IFS=$OIFS
    fi
    
    echo -en "$ret"
}


function warn_to_bullet(){
    repoName=$1
    
    OIFS=$IFS
    ret=""
    if [ "${repo_warnings[$repoName]}" != "" ]; then
        ret="The following warning(s) occured:\n"
        
        IFS='|' 
        for wa in ${repo_warnings[$repoName]}
        do
            ret="$ret  - $wa\n"
        done
        IFS=$OIFS
    fi
    
    echo -en "$ret"
}


#
# Send out an email
#
function send_email(){
    mailType=$1
    repoName=$2
    to=$3
    msg=$4
    
    # Check type: set subject and return if email type is suppressed
    subject="git-puller reporting for '$repoName'"
    if [ "$mailType" == "errors" ]; then
        if [ $SEND_ERROR_MAILS -ne 1 ]; then
            info "Not sending ERROR emails"
            return
        fi
        subject="git-puller reporting errors/warnings for '$repoName'"
    elif [ "$mailType" == "merge" ]; then
        if [ $SEND_MERGE_MAILS -ne 1 ]; then
            info "Not sending MERGE emails"
            return
        fi
        subject="git-puller reporting merge for '$repoName'"
    fi
    
    cc=""
    if [ "$DEV_TEAM_MAIL" != "" ]; then
        cc="\nCc: $DEV_TEAM_MAIL"
    fi
    
    info "Sending email to $to of type '$mailType'"
    $(echo -e "Subject: $subject\nFrom: $MAIL_FROM\nTo:$to$cc\n$msg" | "${MAILER[@]}" "$to")
}

function handle_repo(){
    # get $1 as array
    
    # Cleanup and declare local
    declare -A cfg
    read_config "$1"
    repoConfig=$1
    repoName=`basename "$1" ".conf"`
    
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
            rerror $repoName "Remote is not set and local does not exist - cannot clone"
            return
        fi
    
        info "Cloning remote ${cfg[REMOTE_URI]} to ${cfg[LOCAL_TREE]}"
        git clone ${cfg[REMOTE_URI]} ${cfg[LOCAL_TREE]}
        if [ $? -ne 0 ]; then
            rerror $repoName "Failed to clone remote!"
            return
        fi
    fi
    
    # ensure git
    if [ ! -d "${cfg[LOCAL_TREE]}/.git" ]; then
        rerror $repoName "Folder exists (${cfg[LOCAL_TREE]}) but does not appear to be a git repo"
        return
    fi
    
    
    #
    # If here, we are all good to go with GIT checks! So update
    #
    info "Fetching ${cfg[REMOTE_NAME]} "
    (cdgit && git fetch ${cfg[REMOTE_NAME]} > /dev/null 2>&1 )
    (cdgit && git fetch ${cfg[REMOTE_NAME]} --tags > /dev/null 2>&1)
    
    # Get changes
    remoteFull="${cfg[REMOTE_NAME]}/${cfg[REMOTE_BRANCH]}"
    IFS=',' read -r ahead behind <<<`git_distance ${cfg[LOCAL_TREE]} HEAD "$remoteFull"`
    info "Your current HEAD is $ahead ahead and $behind behind the remote $remoteFull"
    
    # Check for new files
    untracked=`git_untracked "${cfg[LOCAL_TREE]}"`
    if [ $untracked -ne 0 ]; then
        if [ ${cfg[ALLOW_UNTRACKED]} -ne 1 ]; then
            rerror $repoName "Config does not allow untracked"
            return
        else
            rwarn $repoName "Ignoring $untracked untracked files"
        fi
    fi
    
    # Check uncommited (added or not) and new added files
    uncom=`git_uncommited "${cfg[LOCAL_TREE]}"`
    added=`git_new "${cfg[LOCAL_TREE]}"`
    dirty=$(($added+$uncom))
    if [ $dirty -ne 0 ]; then
        if [ ${cfg[ALLOW_DIRTY]} -ne 1 ]; then
            rerror $repoName "Your local tree is DIRTY with $uncom uncommited changes and $added new files - and this is not allowed..."
            return
        fi
        rwarn $repoName "Dirty local tree with $uncom uncommited changes and $added new files - Stashing"
        (cdgit && git stash)
        info "Changes stashed"
        
    fi
    
    # Get current branch
    oldBranch=""
    branch=$(cdgit && git_current_brach)
    info "(1st) Your local branch is '$branch'"
    
    if [ "$branch" == "(detached)" ]; then
        rwarn $repoName "Detached head has been detected"
        if [ ${cfg[ALLOW_DETACHED_HEAD]} -ne 1 ]; then
            rerror $repoName "Detached head is not allowed... exiting"
            return
        fi
        
        # Avoid pointless checkout
        if [ $(($ahead + $behind)) -eq 0 ]; then 
            info "Seems you are spot on! ... Just on different branch! Not updating anything"
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
        rwarn $repoName "Local branch mismatch - different one checked-out"
        if [ ${cfg[ALLOW_DIFFERENT_BRANCH]} -ne 1 ]; then
            rerror $repoName "Different branch is not allowed... exiting"
            return
        fi
        
        # Avoid pointless checkout
        if [ $(($ahead + $behind)) -eq 0 ]; then 
            info "Seems you are spot on! ... Just on different branch! Not updating anything"
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
    # Check ahead
    #
    if [ $ahead -gt 0 ]; then
        
        if [ ${cfg[ALLOW_AHEAD]} -ne 1 ]; then
            rerror $repoName "Your local branch is ahead and this is not allowed inconfig"
            return
        fi
        
        if [ "${cfg[AHEAD_POLICY]}" == "push" ]; then
            warn "A git PUSH will happend at the end to update the remote"
        else
            # EXPERIMENTAL: There are 2 cases... 
            #   - 1. We are indded ahead due to commits
            #   - 2. Someone rolled back the remote!
            
            rwarn $repoName "Someone rolled back the remote branch... we are following"
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
    # This warning indicates when our local repo changed. It is not really a 
    # warning, but we need this in the log file...
    if  [ $behind -gt 0 ]; then
        warn "Merging $repoName"
        (cdgit && git merge "$remoteFull" -m "git-puller merging!")
        rc=$?
        if [ $rc -ne 0 ]; then
            rerror $repoName "Merging failed ... reseting HARD to previous HASH"
            (cdgit && git merge --abort)
            # The following is the same!
            # (cdgit && git reset --hard $currentHash)
            return
        fi
        
        
        # If we merged someting (behind>0) and the repo configuration
        # requests email updates, send
        if [ ${cfg[MERGE_NOTIFICATIONS]} -eq 1 ]; then
                # Successful merge with content
                msg="\nSuccessful merge at $(date +"$DATE_FORMAT") on $(hostname)${cfg[LOCAL_TREE]} for branch '${cfg[LOCAL_BRANCH]}'\n"
                send_email "merge" "$repoName" "${cfg[REPORT_TO]}" "$msg"
        fi
    fi
    
    
    
    #
    # Check local and remote HEADS match
    #
    currentHash=$(cdgit && git rev-parse --verify HEAD)
    currentRemote=$(cdgit && git rev-parse --verify $remoteFull)
    if [ "$currentHash" != "$currentRemote" ]; then
        rwarn $repoName "We are ahead! Pushing to remote"
        (cdgit && git push ${cfg[REMOTE_NAME]} ${cfg[REMOTE_BRANCH]})
    fi
    
    # Check back to the old hash/branch if any
    if [ "$oldBranch" != "" ] && [ ${cfg[DIFFERENT_BRANCH_FIX]} -ne 1 ]; then
        info "Checking back to $oldBranch"
        (cdgit && git checkout "$oldBranch")
    fi
    
    # 
    # Run post-script if:
    #  1. Is there
    #  2. We did a merge...
    #  
    if [ "${cfg[POST_SUCCESS]}" != "" ] && [ $behind -ne 0 ]; then
        if [ -x ${cfg[POST_SUCCESS]} ]; then
            # Arguments: config
            info "Running Post-script ${cfg[POST_SUCCESS]}"
            ${cfg[POST_SUCCESS]} "$repoConfig"
        else
            rwarn $repoName "Configuration error - wrong postscript"
        fi
    fi
    
}

while getopts ":c:l:e" opt; do
    case $opt in
        c) config=$OPTARG ;;
        l) LOG_LEVEL=$OPTARG ;;
        e) 
            info "Not sending emails"
            MAILER=""
        ;;
        h)
            usage
            exit 0
        ;;
        \?)
            usage
            exit 1
        ;;
    esac
done

shift $(($OPTIND - 1))

if [ ! -d $config ]; then
    error "Oooops: Configuration directory... is not actually a directory"
    exit 1
fi

# Log heartbeat
rwarn "HEARTBEAT"

for c in $config/*.conf
do
    info "Handing repo config '$c'"
    handle_repo "$c"
    repoName=`basename $c ".conf"`
    # Notify ppl for this repo
    errstr="$(errors_to_bullet $repoName)"
    warnstr="$(warn_to_bullet $repoName)"
    
    
    if [ "$errstr$warnstr" != "" ];then

        declare -A cfg
        read_config "$c"
        
        branch=${cfg[LOCAL_BRANCH]}
        if [ "$branch" == "" ]; then
            branch="master"
        fi
        msg="\nMessage from git-puller: While running for $(hostname):${cfg[LOCAL_TREE]}, branch '$branch'\n\n"
    
        if [ "$errstr" != "" ]; then
            msg="$msg$errstr\n\n"
        fi
        if [ "$warnstr" != "" ]; then
            msg="$msg$warnstr\n\n"
        fi
        
        
        
        if [ "${cfg[REPORT_TO]}" != "" ] && [ "$MAILER" != "" ]; then
            # Send email type=errors
            send_email "errors" "$repoName" "${cfg[REPORT_TO]}" "$msg"
        fi
    fi
    
    echo -e "$msg"
done


exit 0


