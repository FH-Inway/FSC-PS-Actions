Param(
    [Parameter(HelpMessage = "The GitHub actor running the action", Mandatory = $false)]
    [string] $actor,
    [Parameter(HelpMessage = "The GitHub token running the action", Mandatory = $false)]
    [string] $token,
    [Parameter(HelpMessage = "DynamicsVersion", Mandatory = $false)]
    [string] $dynamicsVersion = "",
    [Parameter(HelpMessage = "Specifies which properties to get from the settings file, default is all", Mandatory = $false)]
    [string] $get = "",
    [Parameter(HelpMessage = "Merge settings from specific environment", Mandatory = $false)]
    [string] $dynamicsEnvironment = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

# IMPORTANT: No code that can fail should be outside the try/catch

try {
    . (Join-Path -Path $PSScriptRoot -ChildPath "..\FSC-PS-Helper.ps1" -Resolve)

    $settings = ReadSettings -baseFolder $ENV:GITHUB_WORKSPACE -workflowName $env:GITHUB_WORKFLOW
    Write-Host "Got settings from setting files"
    if ($get) {
        $getSettings = $get.Split(',').Trim()
    }
    else {
        $getSettings = @($settings.Keys)
    }

    $EnvironmentsFile = Join-Path $ENV:GITHUB_WORKSPACE '.FSC-PS\environments.json'
    $envsFile = (Get-Content $EnvironmentsFile) | ConvertFrom-Json

    $github = (Get-ActionContext)

    Write-Host "Initialized variables"
    $DebugPreference = "Continue"
    $github[0] | select * | ft | Out-String -Stream | Write-Debug
    $github[0] | gm | Out-String -Stream | Write-Debug
    $github[0].Payload[0] | select * | ft | Out-String -Stream | Write-Debug
    $github[0].Payload[0] | gm | Out-String -Stream | Write-Debug
    $github[0].Payload[0].inputs | select * | ft | Out-String -Stream | Write-Debug
    $github[0].Payload[0].inputs | gm | Out-String -Stream | Write-Debug

    $github.Payload.inputs

    if($github[0].Payload[0].PSObject.Properties.name -and $github[0].Payload[0].PSObject.Properties.name -eq "inputs")
    {
        Write-Debug "Checking for payload inputs"
        if($github[0].Payload[0].inputs)
        {
            Write-Debug "Checking inputs"
            $github.Payload.inputs.PSObject.Properties.name -eq "includeTestModels"
            Write-Debug "Analyzing payload inputs"
            if($github[0].Payload[0].inputs[0].PSObject.Properties.name -and $github[0].Payload[0].inputs[0].PSObject.Properties.name -eq "includeTestModels")
            {
                $settings.includeTestModel = ($github[0].Payload[0].inputs[0].includeTestModels -eq "True")
            }
        }
    }

    Write-Host "Determined includeTestModel setting"

    $repoType = $settings.type
    if($dynamicsEnvironment -and $dynamicsEnvironment -ne "*")
    {
        #merge environment settings into current Settings
        $dEnvCount = $dynamicsEnvironment.Split(",").Count
        ForEach($env in $envsFile)
        {
            if($dEnvCount -gt 1)
            {
                $dynamicsEnvironment.Split(",") | ForEach-Object {
                    if($env.name -eq $_)
                    {
                        if($env.settings.PSobject.Properties.name -match "deploy")
                        {
                            $env.settings.deploy = $true
                        }
                        MergeCustomObjectIntoOrderedDictionary -dst $settings -src $env.settings
                    }
                }
            }
            else {
                if($env.name -eq $dynamicsEnvironment)
                {
                    if($env.settings.PSobject.Properties.name -match "deploy")
                    {
                        $env.settings.deploy = $true
                    }
                    MergeCustomObjectIntoOrderedDictionary -dst $settings -src $env.settings
                }
            }
        }
        if($settings.sourceBranch){
            $sourceBranch = $settings.sourceBranch;
        }
        else
        {
            $sourceBranch = $settings.currentBranch;
        }

        if($dEnvCount -gt 1)
        {
            $environmentsJSon = $($dynamicsEnvironment.Split(",")  | ConvertTo-Json -compress)
        }
        else
        {
            $environmentsJson = '["'+$($dynamicsEnvironment).ToString()+'"]'
        }


        Add-Content -Path $env:GITHUB_OUTPUT -Value "SOURCE_BRANCH=$sourceBranch"
        Add-Content -Path $env:GITHUB_ENV -Value "SOURCE_BRANCH=$sourceBranch"

        Add-Content -Path $env:GITHUB_OUTPUT -Value "Environments=$environmentsJson"
        Add-Content -Path $env:GITHUB_ENV -Value "Environments=$environmentsJson"
    }
    else    
    {
        $environments = @($envsFile | ForEach-Object { 
            $check = $true
            if($_.settings.PSobject.Properties.name -match "deploy")
            {
                $check = $_.settings.deploy
            }
            
            if($check)
            {
                if($github.EventName -eq "schedule")
                {
                     $check = Test-CronExpression -Expression $_.settings.cron -DateTime ([DateTime]::Now) -WithDelayMinutes 29
                }
            }
            if($check)
            {
                $_.Name
            }
        })

        if($environments.Count -eq 1)
        {
            $environmentsJson = '["'+$($environments[0]).ToString()+'"]'
        }
        else
        {
            $environmentsJSon = $environments | ConvertTo-Json -compress
        }

        Add-Content -Path $env:GITHUB_OUTPUT -Value "Environments=$environmentsJson"
        Add-Content -Path $env:GITHUB_ENV -Value "Environments=$environmentsJson"
    }

    Write-Host "Determined environment settings"

    if($DynamicsVersion -ne "*" -and $DynamicsVersion)
    {
        $settings.buildVersion = $DynamicsVersion
        
        $ver = Get-VersionData -sdkVersion $settings.buildVersion
        $settings.retailSDKVersion = $ver.retailSDKVersion
        $settings.retailSDKURL = $ver.retailSDKURL
    }



    $outSettings = @{}
    $getSettings | ForEach-Object {
        $setting = $_.Trim()
        $outSettings += @{ "$setting" = $settings."$setting" }
        Add-Content -Path $env:GITHUB_ENV -Value "$setting=$($settings."$setting")"
    }

    $outSettingsJson = $outSettings | ConvertTo-Json -Compress

    Add-Content -Path $env:GITHUB_OUTPUT -Value "Settings=$OutSettingsJson"
    Add-Content -Path $env:GITHUB_ENV -Value "Settings=$OutSettingsJson"

    $gitHubRunner = $settings.githubRunner.Split(',') | ConvertTo-Json -compress
    Add-Content -Path $env:GITHUB_OUTPUT -Value "GitHubRunner=$githubRunner"

    if($settings.buildVersion.Contains(','))
    {
        $versionsJSon = $settings.buildVersion.Split(',') | ConvertTo-Json -compress

        Add-Content -Path $env:GITHUB_OUTPUT -Value "Versions=$versionsJSon"
        Add-Content -Path $env:GITHUB_ENV -Value "Versions=$versionsJSon"
    }
    else
    {
        $versionsJSon = '["'+$($settings.buildVersion).ToString()+'"]'

        Add-Content -Path $env:GITHUB_OUTPUT -Value "Versions=$versionsJSon"
        Add-Content -Path $env:GITHUB_ENV -Value "Versions=$versionsJSon"
    }

    Add-Content -Path $env:GITHUB_OUTPUT -Value "type=$repoType"
    Add-Content -Path $env:GITHUB_ENV -Value "type=$repoType"

}
catch {
    OutputError -message $_.Exception.Message
    exit
}
finally {
}
