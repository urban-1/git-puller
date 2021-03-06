# git-puller

Multi-repo, configuration based unattended git-pull like behavior.

A tool for releasing software using git which supports multiple local 
repositories. `git-puller` performs a `git pull` on
each local git repository configured in order to bring it up-to-date with a 
specific remote branch. It is mainly intended to run via cron and thus it can
handle a few more complex cases that would normally require a human:

1.  Check for modified or new files in the local tree. This should not really 
    happen given that the target tree is not a development tree. However, in 
    such cases `git-puller` will stash any changes.
    
1.  Automatically roll-back to the previous state if/when a merge goes bad
    and there are conflicts that need to be resolved.
    
1.  Handle repositories that are in the wrong branch or detached head. This
    happens when one locks the version forcing it to a specific tag
    or changing to a feature branch. In such cases there are two options: (1)
    back-out and do not change anything and (2) update the tracked branch and 
    checkout again the previous HEAD's commit

1.  Allow the local repository to be *ahead* of the remote one. This can happen
    in few cases including: (1) Editing and committing on the local repo but not
    pushing to remote and (2) Manually rolling-back the branch we are tracking.
    
Additionally, `git-puller` has the following features:

-   Post-pull script: This can be used to update configuration that is not checked
    in the main repository, notify people for the release or ensure correct
    permissions for other teams/groups to edit
-   Email notifications for any warnings or errors detected on a per-repo basis
-   Email notifications when a merge happens successfully
-   Summary notification for all projects (TODO)


## Usage ##

    $ ./puller.sh -h

    Usage: ./puller.sh [options] -c <config>

    Options:
        -e    Do not send emails (disables mailer if configured)
        -l    Message level (10=DEBUG, INFO=20, WARN=30 and ERROR=42 :))



## Configuration  ##

Configuration of `git-puller` is two-fold:

1. The utility configuration: Global options
2. The `config` directory which contains one configuration file per repository that we follow

### Global options ###

Copy the `puller-config.sh.sample` to `puller-config.sh` and edit it to fit your needs. To options are:

##### `MAILER`

A bash array with the mailer commands and arguments, example:

    MAILER=(/usr/sbin/sendmail "-C" ~/.ssmtp.conf)
    
##### `MAIL_FROM`

The `From:` field to be used when sending out emails. Note that both your mailer configuration 
and the SMTP provider should allow this to happen.

##### `SEND_MERGE_MAILS`

`[0|1]` If 0, it will not send any *merge* notifications for any configured repo. 

##### `SEND_ERROR_MAILS`

`[0|1]` If 0, it will not send any *error* notifications for any configured repo. 

##### `DEV_TEAM_MAIL`

If provided, this address will be CCed in all mails sent by `git-puller`

##### `DATE_FORMAT`

The date format used in email reports and logging

##### `LOG_LEVEL`

The default log level if none is provided

##### `KEY_FILE`

Key to be used for `git+ssh://` repos when pulling, pushing and cloning

### Repositories ###

`git-puller` will read every file in the configuration directory that ends with
`.conf`. Therefore, if you need to disable a repo, change or remove the extension.

Now, each configuration file can have the following:

##### `LOCAL_TREE`

Path to local tree. Default is "".

##### `REMOTE_URI`

Complete URI of the remote. This will only be used when cloning for the first time. Default is ""

##### `REMOTE_NAME`

Name of the remote we are tracking. Default "origin"

##### `REMOTE_BRANCH`

Name of the remote branch we are tracking. Default "master"

##### `LOCAL_BRANCH`

Name of the local branch. Default "master"

##### `REPORT_TO`

A string of emails as expected by sendmail `To:` header. These people will be
notified for errors and warnings. If empty, not emails will be sent. Default ""

##### `MERGE_NOTIFICATIONS`

`[0|1]` If 1, puller will send update notifications when it merges branches.

##### `ALLOW_DIRTY`

`[0|1]` If 1 (==True) we allow the local tree to be dirty which means that there are uncommitted
changes. In this case `git-puller` will stash them.

##### `ALLOW_UNTRACKED`

`[0|1]` If 1, we allow the local tree to have new files that have not been added to the
repository. Default 0

##### `ALLOW_AHEAD`

`[0|1]` If 1, we allow the local repository to be ahead of the remote. Default 0

##### `AHEAD_POLICY`

`[push|rollback]`. This has meaning only when ALLOW_AHEAD is 1. 

- If set to "push", `git-puller` will: (1) fetch, (2) merge and (3) push. (recommended)
- If set to rollback, it will: (1) create a new branch named `rollback-<date/time>`,
     (2) delete `LOCAL_BRANCH` and (3) Re-Create `LOCAL_BRANCH` on the `REMOTE_BRANCH` hash/commit. Default ""

Whatever you do, if you plan to edit on the target tree, *do not set this to "rollback"*.


##### `ALLOW_DIFFERENT_BRANCH`

`[0|1]` Allow the local tree to be on a different branch. This can happen if someone 
has manually checked out a feature branch. Default 0

##### `ALLOW_DETACHED_HEAD`

`[0|1]` Allow the local tree to have detached HEAD. Usually happens when one manually 
checks out a tag. Default 0

##### `DIFFERENT_BRANCH_FIX`

`[0|1]` If 1, `git-puller` will leave the tree at the LOCAL_BRANCH, else it will checkout the previous HEAD.
Setting this to 1 means that the local repo cannot be forced to another version or branch - **not recommended**

##### `POST_SUCCESS`

Path to a script/executable to be invoked once everything has finished successfully


