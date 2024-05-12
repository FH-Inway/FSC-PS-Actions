Param(
    [switch] $local
)

$gitHubHelperPath = Join-Path $PSScriptRoot 'Helpers\Github-Helper.psm1'
if (Test-Path $gitHubHelperPath) {
    Import-Module $gitHubHelperPath
}
$lcsHelperPath = Join-Path $PSScriptRoot 'Helpers\LCS-Helper.psm1'
if (Test-Path $lcsHelperPath) {
    Import-Module $lcsHelperPath
}

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
enum LcsAssetFileType {
    Model = 1
    ProcessDataPackage = 4
    SoftwareDeployablePackage = 10
    GERConfiguration = 12
    DataPackage = 15
    PowerBIReportModel = 19
    ECommercePackage = 26
    NuGetPackage = 27
    RetailSelfServicePackage = 28
    CommerceCloudScaleUnitExtension = 29
}       
$ErrorActionPreference = "stop"
Set-StrictMode -Version 2.0
$runningLocal = $false #$local.IsPresent


function ConvertTo-HashTable {
    [CmdletBinding()]
    Param(
        [parameter(ValueFromPipeline)]
        [PSCustomObject] $object
    )
    $ht = @{}
    if ($object) {
        $object.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
    }
    $ht
}

function OutputError {
    Param(
        [string] $message
    )

    if ($runningLocal) {
        throw $message
    }
    else {
        Write-Error "::Error::$message"
        $host.SetShouldExit(1)
    }
}

function OutputWarning {
    Param(
        [string] $message
    )

    if ($runningLocal) {
        Write-Host -ForegroundColor Yellow "WARNING: $message"
    }
    else {
        Write-Host "::Warning::$message"
    }
}

function MaskValueInLog {
    Param(
        [string] $value
    )

    if (!$runningLocal) {
        Write-Host "::add-mask::$value"
    }
}

function OutputInfo {
    [CmdletBinding()]
    param (
        [string]$Message
    )
        filter timestamp {"[ $(Get-Date -Format yyyy.MM.dd-HH:mm:ss) ]: $_"}
        Write-Output ($Message | timestamp)
}
function OutputDebug {
    Param(
        [string] $message
    )

    if ($runningLocal) {
        Write-Host $message
    }
    else {
        Write-Host "::Debug::$message"
    }
}
function Update-7ZipInstallation
{
        # Modern websites require TLS 1.2
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        
        #requires -RunAsAdministrator
        
        # Let's go directly to the website and see what it lists as the current version
        $BaseUri = "https://www.7-zip.org/"
        $BasePage = Invoke-WebRequest -Uri ( $BaseUri + 'download.html' ) -UseBasicParsing
        # Determine bit-ness of O/S and download accordingly
        if ( [System.Environment]::Is64BitOperatingSystem ) {
            # The most recent 'current' (non-beta/alpha) is listed at the top, so we only need the first.
            $ChildPath = $BasePage.Links | Where-Object { $_.href -like '*7z*-x64.msi' } | Select-Object -First 1 | Select-Object -ExpandProperty href
        } else {
            # The most recent 'current' (non-beta/alpha) is listed at the top, so we only need the first.
            $ChildPath = $BasePage.Links | Where-Object { $_.href -like '*7z*.msi' } | Select-Object -First 1 | Select-Object -ExpandProperty href
        }
        
        # Let's build the required download link
        $DownloadUrl = $BaseUri + $ChildPath
        
        Write-Host "Downloading the latest 7-Zip to the temp folder"
        Invoke-WebRequest -Uri $DownloadUrl -OutFile "$env:TEMP\$( Split-Path -Path $DownloadUrl -Leaf )" | Out-Null
        Write-Host "Installing the latest 7-Zip"
        Start-Process -FilePath "$env:SystemRoot\system32\msiexec.exe" -ArgumentList "/package", "$env:TEMP\$( Split-Path -Path $DownloadUrl -Leaf )", "/passive" -Wait
}
function Compress-7zipArchive {
    Param (
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [string] $DestinationPath
    )

    Update-7ZipInstallation
    $7zipPath = "$env:ProgramFiles\7-Zip\7z.exe"

    $use7zip = $false
    if (Test-Path -Path $7zipPath -PathType Leaf) {
        try {
            $use7zip = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($7zipPath).FileMajorPart -ge 19
        }
        catch {
            $use7zip = $false
        }
    }

    if ($use7zip) {
        OutputDebug -message "Using 7zip"
        Set-Alias -Name 7z -Value $7zipPath
        $command = '7z a -t7z "{0}" "{1}"' -f $DestinationPath, $Path
        Invoke-Expression -Command $command | Out-Null
    }
    else {
        OutputDebug -message "Using Compress-Archive"
        Compress-Archive -Path $Path -DestinationPath "$DestinationPath" -Force
    }
}
function Expand-7zipArchive {
    Param (
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [string] $DestinationPath
    )
    Update-7ZipInstallation
    $7zipPath = "$env:ProgramFiles\7-Zip\7z.exe"

    $use7zip = $false
    if (Test-Path -Path $7zipPath -PathType Leaf) {
        try {
            $use7zip = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($7zipPath).FileMajorPart -ge 19
        }
        catch {
            $use7zip = $false
        }
    }

    if ($use7zip) {
        OutputDebug -message "Using 7zip"
        Set-Alias -Name 7z -Value $7zipPath
        $command = '7z x "{0}" -o"{1}" -aoa -r' -f $Path, $DestinationPath
        Invoke-Expression -Command $command | Out-Null
    }
    else {
        OutputDebug -message "Using Expand-Archive"
        Expand-Archive -Path $Path -DestinationPath "$DestinationPath" -Force
    }
}
function MergeCustomObjectIntoOrderedDictionary {
    Param(
        [System.Collections.Specialized.OrderedDictionary] $dst,
        [PSCustomObject] $src
    )

    # Add missing properties in OrderedDictionary

    $src.PSObject.Properties.GetEnumerator() | ForEach-Object {
        $prop = $_.Name
        $srcProp = $src."$prop"
        $srcPropType = $srcProp.GetType().Name
        if (-not $dst.Contains($prop)) {
            if ($srcPropType -eq "PSCustomObject") {
                $dst.Add("$prop", [ordered]@{})
            }
            elseif ($srcPropType -eq "Object[]") {
                $dst.Add("$prop", @())
            }
            else {
                $dst.Add("$prop", $srcProp)
            }
        }
    }

    @($dst.Keys) | ForEach-Object {
        $prop = $_
        if ($src.PSObject.Properties.Name -eq $prop) {
            $dstProp = $dst."$prop"
            $srcProp = $src."$prop"
            $dstPropType = $dstProp.GetType().Name
            $srcPropType = $srcProp.GetType().Name
            if ($srcPropType -eq "PSCustomObject" -and $dstPropType -eq "OrderedDictionary") {
                MergeCustomObjectIntoOrderedDictionary -dst $dst."$prop" -src $srcProp
            }
            elseif ($dstPropType -ne $srcPropType) {
                throw "property $prop should be of type $dstPropType, is $srcPropType."
            }
            else {
                if ($srcProp -is [Object[]]) {
                    $srcProp | ForEach-Object {
                        $srcElm = $_
                        $srcElmType = $srcElm.GetType().Name
                        if ($srcElmType -eq "PSCustomObject") {
                            $ht = [ordered]@{}
                            $srcElm.PSObject.Properties | Sort-Object -Property Name -Culture "iv-iv" | ForEach-Object { $ht[$_.Name] = $_.Value }
                            $dst."$prop" += @($ht)
                        }
                        else {
                            $dst."$prop" += $srcElm
                        }
                    }
                }
                else {
                    $dst."$prop" = $srcProp
                }
            }
        }
    }
}
function Get-AXModelReferences
{
    [CmdletBinding()]
    param (
        [string]
        $descriptorPath
    )
    if(Test-Path "$descriptorPath")
    {
        [xml]$xmlData = Get-Content $descriptorPath
        $modelDisplayName = $xmlData.SelectNodes("//AxModelInfo/ModuleReferences")
        return $modelDisplayName.string 
    }
}

function Get-AXReferencedTestModel
{
    [CmdletBinding()]
    param (
        [string]
        $modelNames,
        [string]
        $metadataPath
    )
    $testModelsList = @()
    $modelNames.Split(",") | ForEach-Object {
        $modelName = $_
        (Get-ChildItem -Path $metadataPath) | ForEach-Object{ 
            $mdlName = $_.BaseName        
            if($mdlName -eq $modelName){ return; } 
            $checkTest = $($mdlName.Contains("Test"))
            if(-not $checkTest){ return; }        
            Write-Host "ModelName: $mdlName"
            $descriptorSearchPath = (Join-Path $_.FullName "Descriptor")
            $descriptor = (Get-ChildItem -Path $descriptorSearchPath -Filter '*.xml')
            if($descriptor)
            {
                $refmodels = (Get-AXModelReferences -descriptorPath $descriptor.FullName)
                Write-Host "RefModels: $refmodels"
                foreach($ref in $refmodels)
                {
                    if($modelName -eq $ref)
                    {
                        if(-not $testModelsList.Contains("$mdlName"))
                        {
                            $testModelsList += ("$mdlName")
                        }
                    }
                }
            }
        }
    }
    return $testModelsList -join ","
}
function Get-FSCModels
{
    [CmdletBinding()]
    param (
        [string]
        $metadataPath,
        [switch]
        $includeTest = $false,
        [switch]
        $all = $false

    )
    if(Test-Path "$metadataPath")
    {
        $modelsList = @()

        (Get-ChildItem -Directory "$metadataPath") | ForEach-Object {

            $testModel = ($_.BaseName -match "Test")

            if ($testModel -and $includeTest) {
                $modelsList += ($_.BaseName)
            }
            if((Test-Path ("$metadataPath/$($_.BaseName)/Descriptor")) -and !$testModel) {
                $modelsList += ($_.BaseName)
            }
            if(!(Test-Path ("$metadataPath/$($_.BaseName)/Descriptor")) -and !$testModel -and $all) {
                $modelsList += ($_.BaseName)
            }
        }
        return $modelsList -join ","
    }
    else 
    {
        Throw "Folder $metadataPath with metadata doesnot exists"
    }
}
function installModules {
    Param(
        [String[]] $modules
    )
    begin{
        Set-MpPreference -DisableRealtimeMonitoring $true
    }
    process{
        $modules | ForEach-Object {
            if($_ -eq "Az")
            {
                Set-ExecutionPolicy RemoteSigned
                try {
                    Uninstall-AzureRm
                }
                catch {
                }
                
            }

            if (-not (get-installedmodule -Name $_ -ErrorAction SilentlyContinue)) {
                Write-Host "Installing module $_"
                Install-Module $_ -Force -AllowClobber | Out-Null
            }
            $onlineModule = Find-Module $_
            $installedModule = get-installedmodule $_
            if($onlineModule.Version -ne $installedModule.Version)
            {
                Write-Host "Updating module $_"
                Update-Module $_ -WarningAction SilentlyContinue | Out-Null
            }
        }

        $modules | ForEach-Object { 
            Write-Host "Importing module $_"
            Import-Module $_ -DisableNameChecking -Force -WarningAction SilentlyContinue | Out-Null
        }
    }
    end{
        Set-MpPreference -DisableRealtimeMonitoring $false
    }
    
}
function ConvertTo-HashTable() {
    [CmdletBinding()]
    Param(
        [parameter(ValueFromPipeline)]
        [PSCustomObject] $object
    )
    $ht = @{}
    if ($object) {
        $object.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
    }
    $ht
}
function GenerateProjectFile {
    [CmdletBinding()]
    param (
        [string]$ModelName,
        [string]$MetadataPath,
        [string]$ProjectGuid
    )

    $ProjectFileName =  'Build.rnrproj'
    $ModelProjectFileName = $ModelName + '.rnrproj'
    $NugetFolderPath =  Join-Path $PSScriptRoot 'NewBuild'
    $SolutionFolderPath = Join-Path  $NugetFolderPath 'Build'
    $ModelProjectFile = Join-Path $SolutionFolderPath $ModelProjectFileName
    #$modelDisplayName = Get-AXModelDisplayName -ModelName $ModelName -ModelPath $MetadataPath 
    $modelDescriptorName = Get-AXModelName -ModelName $ModelName -ModelPath $MetadataPath 
    #generate project file

    if($modelDescriptorName -eq "")
    {
        $ProjectFileData = (Get-Content $ProjectFileName).Replace('ModelName', $ModelName).Replace('62C69717-A1B6-43B5-9E86-24806782FEC2'.ToLower(), $ProjectGuid.ToLower())
    }
    else {
        $ProjectFileData = (Get-Content $ProjectFileName).Replace('ModelName', $modelDescriptorName).Replace('62C69717-A1B6-43B5-9E86-24806782FEC2'.ToLower(), $ProjectGuid.ToLower())
    }
    #$ProjectFileData = (Get-Content $ProjectFileName).Replace('ModelName', $modelDescriptorName).Replace('62C69717-A1B6-43B5-9E86-24806782FEC2'.ToLower(), $ProjectGuid.ToLower())
     
    Set-Content $ModelProjectFile $ProjectFileData
}
function Get-AXModelDisplayName {
    param (
        [Alias('ModelName')]
        [string]$_modelName,
        [Alias('ModelPath')]
        [string]$_modelPath
    )
    process{
        $descriptorSearchPath = (Join-Path $_modelPath (Join-Path $_modelName "Descriptor"))
        $descriptor = (Get-ChildItem -Path $descriptorSearchPath -Filter '*.xml')
        if($descriptor)
        {
            OutputVerbose "Descriptor found at $descriptor"
            [xml]$xmlData = Get-Content $descriptor.FullName
            $modelDisplayName = $xmlData.SelectNodes("//AxModelInfo/DisplayName")
            return $modelDisplayName.InnerText
        }
    }
}
function Get-AXModelName {
    param (
        [Alias('ModelName')]
        [string]$_modelName,
        [Alias('ModelPath')]
        [string]$_modelPath
    )
    process{
        $descriptorSearchPath = (Join-Path $_modelPath (Join-Path $_modelName "Descriptor"))
        $descriptor = (Get-ChildItem -Path $descriptorSearchPath -Filter '*.xml')
        OutputVerbose "Descriptor found at $descriptor"
        [xml]$xmlData = Get-Content $descriptor.FullName
        $modelDisplayName = $xmlData.SelectNodes("//AxModelInfo/Name")
        return $modelDisplayName.InnerText
    }
}
function GenerateSolution {
    [CmdletBinding()]
    param (
        [string]$ModelName,
        [string]$NugetFeedName,
        [string]$NugetSourcePath,
        [string]$DynamicsVersion,
        [string]$MetadataPath
    )

    Set-Location $PSScriptRoot\Build\Build

    OutputDebug "MetadataPath: $MetadataPath"

    $SolutionFileName =  'Build.sln'
    $NugetFolderPath =  Join-Path $PSScriptRoot 'NewBuild'
    $SolutionFolderPath = Join-Path  $NugetFolderPath 'Build'
    $NewSolutionName = Join-Path  $SolutionFolderPath 'Build.sln'
    New-Item -ItemType Directory -Path $SolutionFolderPath -ErrorAction SilentlyContinue
    Copy-Item build.props -Destination $SolutionFolderPath -force
    $ProjectPattern = 'Project("{FC65038C-1B2F-41E1-A629-BED71D161FFF}") = "ModelNameBuild (ISV) [ModelDisplayName]", "ModelName.rnrproj", "{62C69717-A1B6-43B5-9E86-24806782FEC2}"'
    $ActiveCFGPattern = '		{62C69717-A1B6-43B5-9E86-24806782FEC2}.Debug|Any CPU.ActiveCfg = Debug|Any CPU'
    $BuildPattern = '		{62C69717-A1B6-43B5-9E86-24806782FEC2}.Debug|Any CPU.Build.0 = Debug|Any CPU'

    [String[]] $SolutionFileData = @() 

    $projectGuids = @{};
    OutputDebug "Generate projects GUIDs..."
    Foreach($model in $ModelName.Split(','))
    {
        $projectGuids.Add($model, ([string][guid]::NewGuid()).ToUpper())
    }
    OutputDebug $projectGuids

    #generate project files file
    $FileOriginal = Get-Content $SolutionFileName
        
    OutputDebug "Parse files"
    Foreach ($Line in $FileOriginal)
    {   
        $SolutionFileData += $Line
        Foreach($model in $ModelName.Split(','))
        {
            $projectGuid = $projectGuids.Item($model)

            if ($Line -eq $ProjectPattern) 
            {
                OutputDebug "Get AXModel Display Name"
                $modelDisplayName = Get-AXModelDisplayName -ModelName $model -ModelPath $MetadataPath 
                OutputDebug "AXModel Display Name is $modelDisplayName"
                OutputDebug "Update Project line"
                $newLine = $ProjectPattern -replace 'ModelName', $model
                $newLine = $newLine -replace 'ModelDisplayName', $modelDisplayName
                $newLine = $newLine -replace 'Build.rnrproj', ($model+'.rnrproj')
                $newLine = $newLine -replace '62C69717-A1B6-43B5-9E86-24806782FEC2', $projectGuid
                #Add Lines after the selected pattern 
                $SolutionFileData += $newLine                
                $SolutionFileData += "EndProject"
        
            } 
            if ($Line -eq $ActiveCFGPattern) 
            { 
                OutputDebug "Update Active CFG line"
                $newLine = $ActiveCFGPattern -replace '62C69717-A1B6-43B5-9E86-24806782FEC2', $projectGuid
                $SolutionFileData += $newLine
            } 
            if ($Line -eq $BuildPattern) 
            {
                OutputDebug "Update Build line"
                $newLine = $BuildPattern -replace '62C69717-A1B6-43B5-9E86-24806782FEC2', $projectGuid
                $SolutionFileData += $newLine
            } 
        }
    }
    OutputDebug "Save solution file"
    #save solution file 
    Set-Content $NewSolutionName $SolutionFileData;
    #cleanup solution file
    $tempFile = Get-Content $NewSolutionName
    $tempFile | Where-Object {$_ -ne $ProjectPattern} | Where-Object {$_ -ne $ActiveCFGPattern} | Where-Object {$_ -ne $BuildPattern} | Set-Content -Path $NewSolutionName 

    #generate project files
    Foreach($project in $projectGuids.GetEnumerator())
    {
        GenerateProjectFile -ModelName $project.Name -ProjectGuid $project.Value -MetadataPath $MetadataPath 
    }

    Set-Location $PSScriptRoot\Build
    #generate nuget.config
    $NugetConfigFileName = 'nuget.config'
    $NewNugetFile = Join-Path $NugetFolderPath $NugetConfigFileName
    if($NugetFeedName)
    {
        $tempFile = (Get-Content $NugetConfigFileName).Replace('NugetFeedName', $NugetFeedName).Replace('NugetSourcePath', $NugetSourcePath)
    }
    else {
        $tempFile = (Get-Content $NugetConfigFileName).Replace('<add key="NugetFeedName" value="NugetSourcePath" />', '')
    }
    Set-Content $NewNugetFile $tempFile


    Foreach($version in Get-Versions)
    {
        if($version.version -eq $DynamicsVersion)
        {
            $PlatformVersion = $version.data.PlatformVersion
            $ApplicationVersion = $version.data.AppVersion
        }
    }

    #generate packages.config
    $PackagesConfigFileName = 'packages.config'
    $NewPackagesFile = Join-Path $NugetFolderPath $PackagesConfigFileName
    $tempFile = (Get-Content $PackagesConfigFileName).Replace('PlatformVersion', $PlatformVersion).Replace('ApplicationVersion', $ApplicationVersion)
    Set-Content $NewPackagesFile $tempFile

    Set-Location $PSScriptRoot
}

function GeneratePackagesConfig
{
    [CmdletBinding()]
    param (
        [string]$DynamicsVersion
    )

    Set-Location $PSScriptRoot\Build

    $NugetFolderPath =  Join-Path $PSScriptRoot 'NewBuild'
    New-Item -ItemType Directory -Path $NugetFolderPath

    #generate nuget.config
    $NugetConfigFileName = 'nuget.config'
    $NewNugetFile = Join-Path $NugetFolderPath $NugetConfigFileName
    if($NugetFeedName)
    {
        $tempFile = (Get-Content $NugetConfigFileName).Replace('NugetFeedName', $NugetFeedName).Replace('NugetSourcePath', $NugetSourcePath)
    }
    else {
        $tempFile = (Get-Content $NugetConfigFileName).Replace('<add key="NugetFeedName" value="NugetSourcePath" />', '')
    }
    Set-Content $NewNugetFile $tempFile

    #generate packages.config
    Foreach($version in Get-Versions)
    {
        if($version.version -eq $DynamicsVersion)
        {
            $PlatformVersion = $version.data.PlatformVersion
            $ApplicationVersion = $version.data.AppVersion
        }
    }
    $PackagesConfigFileName = 'packages.config'
    $NewPackagesFile = Join-Path $NugetFolderPath $PackagesConfigFileName
    $tempFile = (Get-Content $PackagesConfigFileName).Replace('PlatformVersion', $PlatformVersion).Replace('ApplicationVersion', $ApplicationVersion)
    Set-Content $NewPackagesFile $tempFile

    Set-Location $PSScriptRoot
}

function Update-RetailSDK
{
    [CmdletBinding()]
    param (
        [string]$sdkVersion,
        [string]$sdkPath
    )
    begin
    {
        OutputDebug "SDKVersion is $sdkVersion"
        OutputDebug "SDKPath is $sdkPath"
        $storageAccountName = 'ciellosarchive'
        $storageContainer = 'retailsdk'
        #Just read-only SAS token :)
        $StorageSAStoken = 'sp=r&st=2022-10-26T06:49:19Z&se=2032-10-26T14:49:19Z&spr=https&sv=2021-06-08&sr=c&sig=MXHL7F8liAPlwIxzg8FJNjfwJVIjpLMqUV2HYlyvieA%3D'
        $ctx = New-AzStorageContext -StorageAccountName $storageAccountName -SasToken $StorageSAStoken
        $silent = [System.IO.Directory]::CreateDirectory($sdkPath) 
    }
    process
    {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $version = Get-VersionData -sdkVersion $sdkVersion
        $path = Join-Path $sdkPath ("RetailSDK.$($version.RetailSDKVersion).7z")

        if(!(Test-Path -Path $path))
        {
            OutputDebug "RetailSDK $($version.RetailSDKVersion) is not found."
            if($version.RetailSDKURL)
            {
                OutputDebug "Web request. Downloading..."
                $silent = Invoke-WebRequest -Uri $version.RetailSDKURL -OutFile $path
            }
            else {
                OutputDebug "Azure Blob. Downloading..."
                $silent = Get-AzStorageBlobContent -Context $ctx -Container $storageContainer -Blob ("RetailSDK.$($version.RetailSDKVersion).7z") -Destination $path -ConcurrentTaskCount 10 -Force
            }
        }
        return $path
    }
}
function Get-NuGetVersion
{    
    [CmdletBinding()]
    param (
        [System.IO.DirectoryInfo]$NugetPath
    )
    begin{
        $zipFile = [IO.Compression.ZipFile]::OpenRead($NugetPath.FullName)
    }
    process{
        
        $zipFile.Entries | Where-Object {$_.FullName.Contains(".nuspec")} | ForEach-Object{
            $nuspecFilePath = "$(Join-Path $NugetPath.Parent.FullName $_.Name)"
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($_, $nuspecFilePath, $true)

            [xml]$XmlDocument = Get-Content $nuspecFilePath
            $XmlDocument.package.metadata.version
            Remove-Item $nuspecFilePath
        }
    }
    end{
        $zipFile.Dispose()
    }
}
function Get-VersionData
{
    [CmdletBinding()]
    param (
        [string]$sdkVersion
    )
    begin{
        $versionsDefaultFile = Join-Path "$PSScriptRoot" "Helpers\versions.default.json"
        $versionsDefault = (Get-Content $versionsDefaultFile) | ConvertFrom-Json 
        try {
            $versionsFile = Join-Path $ENV:GITHUB_WORKSPACE '.FSC-PS\versions.json'        

            if(Test-Path $versionsFile)
            {
                $versions = (Get-Content $versionsFile) | ConvertFrom-Json
                ForEach($version in $versions)
                { 
                    ForEach($versionDefault in $versionsDefault)
                    {
                        if($version.version -eq $versionDefault.version)
                        {
                
                            if($version.data.PSobject.Properties.name -match "AppVersionGA")
                            {
                                if($version.data.AppVersionGA -ne "")
                                {
                                    $versionDefault.data.AppVersionGA = $version.data.AppVersionGA
                                }
                            }
                            if($version.data.PSobject.Properties.name -match "PlatformVersionGA")
                            {
                                if($version.data.PlatformVersionGA -ne "")
                                {
                                    $versionDefault.data.PlatformVersionGA = $version.data.PlatformVersionGA
                                }
                            }
                            if($version.data.PSobject.Properties.name -match "AppVersionLatest")
                            {
                                if($version.data.AppVersionLatest -ne "")
                                {
                                    $versionDefault.data.AppVersionLatest = $version.data.AppVersionLatest
                                }
                            }
                            if($version.data.PSobject.Properties.name -match "PlatformVersionLatest")
                            {
                                if($version.data.PlatformVersionLatest -ne "")
                                {
                                    $versionDefault.data.PlatformVersionLatest = $version.data.PlatformVersionLatest
                                }
                            }
                            if($version.data.PSobject.Properties.name -match "RetailSDKURL")
                            {
                                if($version.data.RetailSDKURL -ne "")
                                {
                                    $versionDefault.data.RetailSDKURL = $version.data.RetailSDKURL
                                }
                            }
                            if($version.data.PSobject.Properties.name -match "RetailSDKVersion")
                            {
                                if($version.data.RetailSDKVersion -ne "")
                                {
                                    $versionDefault.data.RetailSDKVersion = $version.data.RetailSDKVersion
                                }
                            }
                        }
                    }
                }
            }
        }
        catch {
            <#Do this if a terminating exception happens#>
        }       
       
    }
    process
    {
        foreach($d in $versionsDefault)
        {
            if($d.version -eq $sdkVersion)
            {
                $data = @{
                    AppVersion                      = $d.data.AppVersionLatest
                    PlatformVersion                 = $d.data.PlatformVersionLatest
                    RetailSDKVersion                = $d.data.RetailSDKVersion
                    RetailSDKURL                    = $d.data.RetailSDKURL
                    FSCServiseUpdatePackageId       = $d.data.FSCServiseUpdatePackageId
                    FSCPreviewVersionPackageId      = $d.data.FSCPreviewVersionPackageId
                    FSCLatestQualityUpdatePackageId = $d.data.FSCLatestQualityUpdatePackageId
                    FSCFinalQualityUpdatePackageId  = $d.data.FSCFinalQualityUpdatePackageId
                    EcommerceMicrosoftRepoBranch    = $d.data.EcommerceMicrosoftRepoBranch
                }
                      
                $object = New-Object PSObject -Property $data
                Write-Output $object
            }
        }
    }
}
function Get-Versions
{
    [CmdletBinding()]
    param (
    )

    process
    {
        $versionsDefaultFile = Join-Path "$PSScriptRoot" "Helpers\versions.default.json"
        $versionsDefault = (Get-Content $versionsDefaultFile) | ConvertFrom-Json 
        $versionsFile = Join-Path $ENV:GITHUB_WORKSPACE '.FSC-PS\versions.json'
        

        if(Test-Path $versionsFile)
        {
            $versions = (Get-Content $versionsFile) | ConvertFrom-Json
            ForEach($version in $versions)
            { 
                ForEach($versionDefault in $versionsDefault)
                {
                    if($version.version -eq $versionDefault.version)
                    {
            
                        if($version.data.PSobject.Properties.name -match "AppVersion")
                        {
                            if($version.data.AppVersion -ne "")
                            {
                                $versionDefault.data.AppVersion = $version.data.AppVersion
                            }
                        }
                        if($version.data.PSobject.Properties.name -match "PlatformVersion")
                        {
                            if($version.data.PlatformVersion -ne "")
                            {
                                $versionDefault.data.PlatformVersion = $version.data.PlatformVersion
                            }
                        }
                        if($version.data.PSobject.Properties.name -match "RetailSDKURL")
                        {
                            if($version.data.RetailSDKURL -ne "")
                            {
                                $versionDefault.data.RetailSDKURL = $version.data.RetailSDKURL
                            }
                        }
                        if($version.data.PSobject.Properties.name -match "RetailSDKVersion")
                        {
                            if($version.data.RetailSDKVersion -ne "")
                            {
                                $versionDefault.data.RetailSDKVersion = $version.data.RetailSDKVersion
                            }
                        }
                    }
                }
            }
        }
        Write-Output ($versionsDefault)
    }
}

################################################################################
# Start - Private functions.
################################################################################

function Get-LocString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Key,
        [Parameter(Position = 2)]
        [object[]]$ArgumentList = @( ))

    # Due to the dynamically typed nature of PowerShell, a single null argument passed
    # to an array parameter is interpreted as a null array.
    if ([object]::ReferenceEquals($null, $ArgumentList)) {
        $ArgumentList = @( $null )
    }

    # Lookup the format string.
    $format = ''
    if (!($format = $script:resourceStrings[$Key])) {
        # Warn the key was not found. Prevent recursion if the lookup key is the
        # "string resource key not found" lookup key.
        $resourceNotFoundKey = 'PSLIB_StringResourceKeyNotFound0'
        if ($key -ne $resourceNotFoundKey) {
            Write-Warning (Get-LocString -Key $resourceNotFoundKey -ArgumentList $Key)
        }

        # Fallback to just the key itself if there aren't any arguments to format.
        if (!$ArgumentList.Count) { return $key }

        # Otherwise fallback to the key followed by the arguments.
        $OFS = " "
        return "$key $ArgumentList"
    }

    # Return the string if there aren't any arguments to format.
    if (!$ArgumentList.Count) { return $format }

    try {
        [string]::Format($format, $ArgumentList)
    } catch {
        Write-Warning (Get-LocString -Key 'PSLIB_StringFormatFailed')
        $OFS = " "
        "$format $ArgumentList"
    }
}
function ConvertTo-OrderedDictionary
{
    #requires -Version 2.0

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [hashtable]
        $InputObject,

        [Type]
        $KeyType = [string]
    )

    process
    {
        #$outputObject = New-Object "System.Collections.Generic.Dictionary[[$($KeyType.FullName)],[Object]]"
        $outputObject = New-Object "System.Collections.Specialized.OrderedDictionary"

        foreach ($entry in $InputObject.GetEnumerator())
        {
            $newKey = $entry.Key -as $KeyType
            
            if ($null -eq $newKey)
            {
                throw 'Could not convert key "{0}" of type "{1}" to type "{2}"' -f
                      $entry.Key,
                      $entry.Key.GetType().FullName,
                      $KeyType.FullName
            }
            elseif ($outputObject.Contains($newKey))
            {
                throw "Duplicate key `"$newKey`" detected in input object."
            }

            $outputObject.Add($newKey, $entry.Value)
        }

        Write-Output $outputObject
    }
}
function Import-D365FSCSource
{
    [CmdletBinding()]
    param (
        [string]
        $archivePath,
        [string]
        $targetPath

    )

    $tempFolder = "$targetPath\_tmp"
    Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue -Confirm:$false
    Expand-7zipArchive -Path $archivePath -DestinationPath $tempFolder

    $modelPath = Get-ChildItem -Path $tempFolder -Filter Descriptor -Recurse -ErrorAction SilentlyContinue -Force
    $metadataPath = $modelPath[0].Parent.Parent.FullName
    
    Get-ChildItem -Path $metadataPath | ForEach-Object {
        $_.Name
        #if(Get-ChildItem -Path $_.FullName -Filter Descriptor -Recurse -ErrorAction SilentlyContinue -Force)
        #{
            Copy-Item -Path "$metadataPath\$($_.Name)" -Destination (Join-Path $targetPath "PackagesLocalDirectory\$($_.Name)") -Recurse -Force
        #}
    }
    try {
        $solutionPath = Get-ChildItem -Path $tempFolder -Filter *.sln -Recurse -ErrorAction SilentlyContinue -Force
        $projectsPath = $solutionPath[0].Directory.Parent.FullName
        $projectsPath
        if(Test-Path (Join-Path $targetPath "VSProjects"))
        {
            Copy-Item -Path "$projectsPath\" -Destination (Join-Path $targetPath "VSProjects") -Recurse -Force
        }
    }
    catch {
        Write-Output "Solution files were not found!"
    }

    Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue -Confirm:$false
}
function Update-D365FSCISVSource
{
    [CmdletBinding()]
    param (
        [string]
        $archivePath,
        [string]
        $targetPath

    )

    $tempFolder = "$targetPath\_tmp"
    Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue -Confirm:$false
    #check is archive contains few archives

    $archivePaths = [System.Collections.ArrayList]@()
    $isArchivesInside = $false

    $zipFile = [IO.Compression.ZipFile]::OpenRead($archivePath)
    $zipFile.Entries | Where-Object {$_.FullName.Contains(".zip")} | ForEach-Object{
        $isArchivesInside = $true
    }   
    $zipFile.Dispose()
    ##if archive doesnt contain the archives, add the base path
    if($isArchivesInside)
    {
        Unblock-File $archivePath
        Expand-7zipArchive -Path $archivePath -DestinationPath "$tempFolder/archives"
        Get-ChildItem "$tempFolder/archives" -Filter '*.zip' -Recurse -ErrorAction SilentlyContinue -Force | ForEach-Object {
            $archivePaths.Add($_.FullName)
        }
    }
    else {
        $archivePaths.Add($archivePath)
    }
    foreach($archive in $archivePaths)
    {
        Unblock-File $archive
        Expand-7zipArchive -Path $archive -DestinationPath $tempFolder
        $ispackage = Get-ChildItem -Path $tempFolder -Filter 'AXUpdateInstaller.exe' -Recurse -ErrorAction SilentlyContinue -Force

        if($ispackage)
        {
            Write-Host "Package"
            $models = Get-ChildItem -Path $tempFolder -Filter "dynamicsax-*.zip" -Recurse -ErrorAction SilentlyContinue -Force
            foreach($model in $models)
            {            
                $zipFile = [IO.Compression.ZipFile]::OpenRead($model.FullName)
                $zipFile.Entries | Where-Object {$_.FullName.Contains(".xref")} | ForEach-Object{
                    $modelName = $_.Name.Replace(".xref", "")
                    $targetModelPath = (Join-Path $targetPath "PackagesLocalDirectory/$modelName/")   
                    Expand-7zipArchive -Path $models.FullName -DestinationPath $targetModelPath
                    Remove-Item $targetModelPath/$_ -Force 
                }            
                $zipFile.Dispose()
            }
        }
        else
        {   
            Write-Host "Archive found"
            $modelPath = Get-ChildItem -Path $tempFolder -Filter Descriptor -Recurse -ErrorAction SilentlyContinue -Force
            if(!$modelPath)
            {
                $modelPath = Get-ChildItem -Path $tempFolder -Filter bin -Recurse -ErrorAction SilentlyContinue -Force
            }
            $metadataPath = $modelPath[0].Parent.Parent.FullName
            
            Get-ChildItem -Path $metadataPath | ForEach-Object {
                $_.Name
                Remove-Item -Path (Join-Path $targetPath "PackagesLocalDirectory\$($_.Name)") -Recurse -Force -ErrorAction SilentlyContinue -Confirm:$false
                Copy-Item -Path "$metadataPath\$($_.Name)" -Destination (Join-Path $targetPath "PackagesLocalDirectory\$($_.Name)") -Recurse -Force
            }      
        }  
        
    }
    Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue -Confirm:$false  
}
function Update-Readme
{
    Install-Module PowerShell-yaml -Force
    Get-ChildItem .\Actions -Directory
    Get-ChildItem .\Actions -Directory | ForEach-Object{
        $yamlFile = (Join-Path $_.FullName action.yaml)
        if(Test-Path -Path $yamlFile)
        {
            $readmeContent = ''
            $yaml = Get-Content $yamlFile | ConvertFrom-Yaml
            $readmeContent += "# :rocket: Action '$($_.BaseName)' `n"
            $readmeContent += "$($yaml.name) `n"
            $readmeContent += "## :wrench: Parameters `n"
            
            if($yaml.inputs)
            {
                $readmeContent += "## :arrow_down: Inputs `n"
                $yaml.inputs.GetEnumerator() | ForEach-Object{
                    
                    $readmeContent += "### $($_.Key) (Default: '$($_.Value.Default)') `n"
                    $readmeContent += " $($_.Value.Description) `n"
                    $readmeContent += "`n"
                }
                
            }
            
            if($yaml.outputs)
            {
                $readmeContent += "## :arrow_up: Outputs `n"
                $yaml.outputs.GetEnumerator() | ForEach-Object{
                    
                    $readmeContent += "### $($_.Key) (Default: '$($_.Value.Default)') `n"
                    $readmeContent += " $($_.Value.Description) `n"
                    $readmeContent += "`n"
                }
                
            }
            Set-Content -Path (Join-Path $_.FullName README.md) -Value $readmeContent
        }
    }
}
function Copy-ToDestination
{
    param(
        [string]$RelativePath,
        [string]$File,
        [string]$DestinationFullName
    )

    $searchFile = Get-ChildItem -Path $RelativePath -Filter $File -Recurse
    if (-NOT $searchFile) {
        throw "$File file was not found."
    }
    else {
        Copy-Item $searchFile.FullName -Destination "$DestinationFullName"
    }
}
function ClearExtension {
    param (
        [System.IO.DirectoryInfo]$filePath
    )
    Write-Output ($filePath.BaseName.Replace($filePath.Extension,""))
}
function Check-AzureVMState
{
    [CmdletBinding()]
    param (
        [string]$VMName,
        [string]$VMGroup,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret
    )
    begin{
        if(-not(Test-Path -Path "C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin\"))
        {
            Write-Host "az cli installing.."
            $ProgressPreference = 'SilentlyContinue'; Invoke-WebRequest -Uri https://aka.ms/installazurecliwindows -OutFile .\AzureCLI.msi; Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /quiet'; Remove-Item .\AzureCLI.msi
            Write-Host "az cli installed.."
        }
        Set-Alias -Name az -Value "C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
        $AzureRMAccount = az login --service-principal --username "$ClientId" --password "$ClientSecret" --tenant $TenantId
    }
    process{
        if($AzureRMAccount)
        {
            $PowerState = ([string](az vm get-instance-view --name $VMName --resource-group $VMGroup --query instanceView.statuses[1] | ConvertFrom-Json).DisplayStatus).Trim().Trim("[").Trim("]").Trim('"').Trim("VM ").Replace(' ','')
            return $PowerState
        }
    }
}
################################################################################
# End - Private functions.
################################################################################
