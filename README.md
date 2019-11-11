# CodeAnalyzer
Code analysis tools for PowerShell

## Usage

Clone to this repository to the `Documents\WindowsPowerShell\Modules\` of your `HOME` folder. Then you can use it by importing:

```PS
PS > Import-Module CodeAnalyzer
```

### Available functions

- `Use-FirstCommit`
- `Use-LastCommit`
- `Use-NextCommit`
- `Get-MergeCommits`
- `ConvertTo-SonarResults`
- `Send-SonarReport`
- `Send-ReportHistory`
- `Get-ContributionMatrix`
- `Get-FileStatsFromSonar`

Use `Get-Help -Full <function name>` to get more information on these.
