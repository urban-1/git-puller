# git-puller

Multi-repo, configuration based unattended git-pull like behavior.

A tool for releasing software using git. `git-puller` performs a `git pull` on
each local git repository configured in order to bring it up to date with a 
specific remote branch. It is mainly intended to run via cron and thus it can
handle a few more complex cases that would normally require a human:

1.  Check for modified or new files in the development 
    This should not really happen given that the target tree is not a development
    tree. However, in such cases `git-puller` will stash any changes.
    
1.  Automatically roll-back to the previous state if/when a merge does bad
    and there are conflicts that need to be resolved.
    
1.  Handle repositories that are in the wrong branch or detached head. This
    happens when one locks the version forcing it to a specific tag
    or changing to a feature branch. In such cases there are two options: (1)
    back-out and do not change anything and (2) update the tracked branch and 
    checkout again the previous HEAD's commit

1.  Allow the local repository to be *ahead* of the remote one. This can happen
    in few cases including: (1) Editing and committing but not pushing to remote
    (on the local repo) and (2) Manually rolling-back a specific branch.