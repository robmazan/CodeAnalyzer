<#
.SYNOPSIS

Runs the Sonar scanner and sends the report to the SonarQube server.

.DESCRIPTION

Runs the Sonar scanner and sends the report to the SonarQube server.
Can be used for historical report upload only, as it sets the sonar.projectDate property to the date of the current commit.
Sets the sonar.projectVersion to the full timestamp of the current commit.
#>
function Send-SonarReport {
    param (
        # SonarQube project key where the report should be uploaded to
        [Parameter(Mandatory=$true)]
        [string]
        $projectKey
    )
    $commitTime=git show --no-patch --no-notes --pretty='%ci'
    $commitDate=$commitTime.Substring(0,10)
    $author=git show -s --format='%an' $commit
    Write-Host "Running scan (date: $commitDate, author: $author, version: $commitTime)" -BackgroundColor Red
    try {
        sonar-scanner "-Dsonar.projectKey=$projectKey" "-Dsonar.projectDate=$commitDate" "-Dsonar.projectVersion=$commitTime" "-Dsonar.analysis.author=$author" > $null 3>&1 2>&1
    }
    catch {
        Write-Host "Error during Sonar scan:"
        Write-Host $_
    }
}

<#
.SYNOPSIS

Checks out the given commit.

.OUTPUTS

Git log entry for the commit checked out
#>
function Use-Commit {
    param (
        # Hashcode of the commit to be checked out
        [Parameter(Mandatory=$true)]
        [string]
        $hash
    )

    Write-Host "Checking out commit $commit..." -BackgroundColor DarkGreen
    git checkout $commit
    git log --format=%B -n 1 $commit
}

<#
.SYNOPSIS

Checks out the first commit of the given branch.
#>
function Use-FirstCommit {
    param (
        # Branch name to be used to find its first commit
        [string]
        $branch = "master"
    )
    
    $commits=git rev-list --reverse $branch
    $commit=$commits[0]

    Use-Commit -hash "$commit"
}

<#
.SYNOPSIS

Checks out the last commit of the given branch.
#>
function Use-LastCommit {
    param (
        # Branch name to be used to find its last commit
        [string]
        $branch = "master"
    )
    
    $commits=git rev-list $branch
    $commit=$commits[0]

    Use-Commit -hash "$commit"
}

<#
.SYNOPSIS

Checks out the next commit of the given branch.
#>
function Use-NextCommit {
    param (
        # Branch name to be used to find its next commit
        [string]
        $branch = "master",
        # If you provide a step size, then it jumps $step commits forward.
        # You can skip commits this way.
        [int16]
        $step = 1
    )
    
    [array]$commits=git rev-list --reverse $branch
    $current=git rev-parse HEAD
    $nextIdx=$commits.IndexOf($current) + $step
    $commitCount = $commits.Count
    if ($nextIdx -ge $commitCount) {
        Write-Host "No more commits."
        $commit=$commits[$commitCount-1]
    } else {
        $commit=$commits[$nextIdx]
    }

    Use-Commit -hash "$commit"
}

<#
.SYNOPSIS

Build and send historical reports to SonarQube by going through commits.
#>
function Send-ReportHistory {
    param (
        # Branch name to get commits from
        [string]$branch = "master",
        # SonarQube project key
        [string]$projectKey,
        # Step size to go through commits
        # Only used when the -mergesOnly option is not set
        [int16]$step = 1,
        # Report merge commits only
        [switch]$mergesOnly
    )
    if ($mergesOnly) {
        Send-Merges -branch "$branch" -projectKey "$projectKey"
    } else {
        Send-Commits -branch "$branch" -projectKey "$projectKey" -step $step
    }
}

<#
.SYNOPSIS

Collect merge commits

.OUTPUTS

An array of commit objects with the following fields:

- [string]hash:    Commit hash
- [DateTime]date:  Commit date
- [string]author:  Author's name
- [string]subject: Commit message subject
#>
function Get-MergeCommits() {
    param (
        # Branch name to get merge commits from
        [string]$branch = "master"
    )
    $delim = "|"
    $prettyFormat=[string]::Join($delim, @("%H","%ci", "%an", "%s"))
    $header=@('hash','date','author','subject')
    $commits=git log --merges --first-parent "$branch" --pretty="format:$prettyFormat" --reverse
    $commits | ConvertFrom-Csv -Delimiter $delim -Header $header | ForEach-Object {$_.date=[DateTime]::ParseExact($_.date, "yyyy-MM-dd HH:mm:ss zzz", $null); $_}
}

function Send-Merges {
    param (
        $branch = "master",
        $projectKey
    )
    $commits = Get-MergeCommits -branch "$branch" | Group-Object -Property {$_.date.ToString("yyyyMMdd")} | ForEach-Object {$_.Group[-1].hash}
    $commitCount=$commits.Count
    for ($commitIdx=0; $commitIdx -lt $commitCount; $commitIdx++) {
        $commit = $commits[$commitIdx]
        $commitNo = $commitIdx+1
        $percent = $commitNo*100/$commitCount

        Use-Commit -hash $commit
        Write-Progress -Activity "Processing merge commits..." -Status "$commitNo/$commitCount" -PercentComplete $percent

        Send-SonarReport -project "$projectKey"
    }
}

function Send-Commits {
    param (
        $branch = "master",
        $projectKey,
        $step = 1
    )
    Use-FirstCommit -branch "$branch"
    Send-SonarReport -project "$projectKey"
    $hasCommit=Use-NextCommit -branch "$branch" -step $step
    while ($hasCommit) {
        Send-SonarReport -project "$projectKey"
        $hasCommit=Use-NextCommit -branch "$branch" -step $step
    }
}

<#
.SYNOPSIS

Extend merge commit objects with SonarQube statistics.

.DESCRIPTION

Extend merge commit objects with SonarQube statistics.
Adds number of bugs, code smells, vulnerabilities, reliability rating, 
security rating, and sqale rating for each commit with a daily granularity.

.LINK

Get-MergeCommits
#>
Filter ConvertTo-SonarResults() {
    param (
        # Sonar server URL to get information from
        [string]$server = "http://sonar.mshome.net:9000",
        # Component on Sonar server (a.k.a project key)
        $component,
        # Credential to use to authenticate to the Sonar server
        [pscredential]$credential
    )
    $date=$_.date.ToString("yyyy-MM-dd")
    $body=@{
        component=$component;
        from=$date;
        to=$date;
        metrics="bugs,code_smells,vulnerabilities,reliability_rating,security_rating,sqale_rating"
    }
    $sonarResult=Invoke-RestMethod -Method Get -Uri "$server/api/measures/search_history" -Credential $credential -Body $body
    foreach ($measure in $sonarResult.measures) {
        Add-Member -InputObject $_ NoteProperty $measure.metric $measure.history[0].value
    }
    $_
}

<#
.SYNOPSIS

Create a Git contribution matrix.

.OUTPUTS

Outputs an array of objects, one item per file, each item contains
the number of contributed lines to the given file, the key is the
contributor's name.
#>
function Get-ContributionMatrix() {
    param (
        # Regular expression for file names to include (for example: "\.(ts|js|s?css|html)$")
        [string]$fileNameRegex=".*"
    )
    $authors=git log --format="%aN" | Sort-Object -Unique
    $rowProto = @{file = ""}
    $authors | ForEach-Object { $rowProto.Add($_, 0) }
    git ls-files | Where-Object {$_ -Match "$fileNameRegex"} | ForEach-Object {
        $res=$rowProto.Clone(); 
        $res.file=$_; 
        $stats=git blame --line-porcelain "$_" | Where-Object {$_ -Match "^author "} | ForEach-Object {$_.Substring(7)} | Group-Object;
        foreach ($stat in $stats) { $res[$stat.Name]=$stat.Count }
        $res | ConvertTo-Json | ConvertFrom-Json 
    }
}
<#
.SYNOPSIS

Get metrics from Sonar per file.
#>
Function Get-FileStatsFromSonar() {
    param (
        # Sonar server URL to get information from
        [string]$server = "http://sonar.mshome.net:9000",
        # Component on Sonar server (a.k.a project key)
        [Parameter(Mandatory=$true)]
        [string]$component,
        # Regular expression for file names to include (for example: "\.(ts|js|s?css|html)$")
        [string]$fileNameRegex=".*",
        # Credential to use to authenticate to the Sonar server
        [pscredential]$credential
    )
    $rowProto = @{
        file = "";
        bugs = 0;
        code_smells = 0;
        vulnerabilities = 0;
    }
    git ls-files | Where-Object {$_ -Match "$fileNameRegex"} | ForEach-Object {
        $res=$rowProto.Clone()
        $res.file=$_
        $body=@{
            ps=500;
            component=[string]::Join(":", @($component, $_));
            metricKeys="bugs,code_smells,vulnerabilities";
            strategy="children";
            s="qualifier,name"
        }
        try {
            $sonarResult=Invoke-RestMethod -Method Get -Uri "$server/api/measures/component_tree" -Credential $credential -Body $body
            foreach ($measure in $sonarResult.baseComponent.measures) { $res[$measure.metric]=$measure.value }
        } catch {
        }
        $res | ConvertTo-Json | ConvertFrom-Json 
    }
}

Export-ModuleMember -Function Use-FirstCommit
Export-ModuleMember -Function Use-LastCommit
Export-ModuleMember -Function Use-NextCommit
Export-ModuleMember -Function Get-MergeCommits
Export-ModuleMember -Function ConvertTo-SonarResults
Export-ModuleMember -Function Send-SonarReport
Export-ModuleMember -Function Send-ReportHistory
Export-ModuleMember -Function Get-ContributionMatrix
Export-ModuleMember -Function Get-FileStatsFromSonar
