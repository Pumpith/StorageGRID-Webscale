﻿$AWS_PROFILE_PATH = "$HOME/.aws/"
$AWS_CREDENTIALS_FILE = $AWS_PROFILE_PATH + "credentials"
$AWS_CONFIG_FILE = $AWS_PROFILE_PATH + "config"

# workarounds for PowerShell issues
if ($PSVersionTable.PSVersion.Major -lt 6) {
    Add-Type @"
        using System.Net;
        using System.Security.Cryptography.X509Certificates;
        public class TrustAllCertsPolicy : ICertificatePolicy {
           public bool CheckValidationResult(
                ServicePoint srvPoint, X509Certificate certificate,
                WebRequest request, int certificateProblem) {
                return true;
            }
        }
"@

    # Using .NET JSON Serializer as JSON serialization included in Invoke-WebRequest has a length restriction for JSON content
    Add-Type -AssemblyName System.Web.Extensions
    $global:javaScriptSerializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $global:javaScriptSerializer.MaxJsonLength = [System.Int32]::MaxValue
    $global:javaScriptSerializer.RecursionLimit = 99
}
else {
    # unfortunately AWS Authentication is not RFC-7232 compliant (it is using semicolons in the value) 
    # and PowerShell 6 enforces strict header verification by default
    # therefore disabling strict header verification until AWS fixed this
    $PSDefaultParameterValues.Add("Invoke-WebRequest:SkipHeaderValidation",$true)
}

### Helper Functions ###

function ParseErrorForResponseBody($Error) {
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        if ($Error.Exception.Response) {  
            $Reader = New-Object System.IO.StreamReader($Error.Exception.Response.GetResponseStream())
            $Reader.BaseStream.Position = 0
            $Reader.DiscardBufferedData()
            $ResponseBody = $Reader.ReadToEnd()
            if ($ResponseBody.StartsWith('{')) {
                $ResponseBody = $ResponseBody | ConvertFrom-Json | ConvertTo-Json
            }
            return $ResponseBody
        }
    }
    else {
        return $Error.ErrorDetails.Message
    }
}

function ConvertTo-SortedDictionary($HashTable) {
    $SortedDictionary = New-Object 'System.Collections.Generic.SortedDictionary[string, string]'
    foreach ($Key in $HashTable.Keys) {
        $SortedDictionary[$Key]=$HashTable[$Key]
    }
    Write-Output $SortedDictionary
}

function Get-SignedString {
    [CmdletBinding()]

    PARAM (
        [parameter(Mandatory=$True,
                    Position=0,
                    ValueFromPipeline=$True,
                    ValueFromPipelineByPropertyName=$True,
                    HelpMessage="Key in Bytes.")][Byte[]]$Key,
        [parameter(Mandatory=$False,
                    Position=1,
                    ValueFromPipeline=$True,
                    ValueFromPipelineByPropertyName=$True,
                    HelpMessage="Unit of timestamp.")][String]$Message="",
        [parameter(Mandatory=$False,
                    Position=2,
                    HelpMessage="Algorithm to use for signing.")][ValidateSet("SHA1","SHA256")][String]$Algorithm="SHA256"
    )

    PROCESS {
        if ($Algorithm -eq "SHA1") {
            $Signer = New-Object System.Security.Cryptography.HMACSHA1
        }
        else {
            $Signer = New-Object System.Security.Cryptography.HMACSHA256
        }

        $Signer.Key = $Key
        $Signer.ComputeHash([Text.Encoding]::UTF8.GetBytes($Message))
    }
}

function Sign($Key,$Message) {
    $hmacsha = New-Object System.Security.Cryptography.HMACSHA256
    $hmacsha.Key = $Key
    $hmacsha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Message))
}

function GetSignatureKey($Key, $Date, $Region, $Service) {
    $SignedDate = sign ([Text.Encoding]::UTF8.GetBytes(('AWS4' + $Key).toCharArray())) $Date
    $SignedRegion = sign $SignedDate $Region
    $SignedService = sign $SignedRegion $Service
    sign $SignedService "aws4_request"
}

function ConvertFrom-AwsConfigFile {
    [CmdletBinding()]

    PARAM (
        [parameter(
            Mandatory=$True,
            Position=0,
            HelpMessage="AWS Config File")][String]$AwsConfigFile
    )

    Process {
        if (!(Test-Path $AwsConfigFile))
        {
            throw "Config file $AwsConfigFile does not exist!"
        }
        $Content = Get-Content -Path $AwsConfigFile -Raw
        # remove empty lines
        $Content = $Content -replace "(`n$)*", ""
        # convert to JSON structure
        $Content = $Content -replace "profile ", ""
        $Content = $Content -replace "`n([^\[])", ',$1'
        $Content = $Content -replace "\[", "{`"profile = "
        $Content = $Content -replace "]", ""
        $Content = $Content -replace "\s*=\s*", "`":`""
        $Content = $Content -replace ",", "`",`""
        $Content = $Content -replace "`n", "`"},"
        $Content = $Content -replace "^", "["
        $Content = $Content -replace "$", "`"}]"
        $Content = $Content -replace "{`"}", "{}"

        # parse JSON
        Write-Debug "Content to convert:`n$Content"

        if ($Content -match "{.*}") {
            $Config = ConvertFrom-Json -InputObject $Content
            $Config = $Config | Select-Object -Property profile, aws_access_key_id, aws_secret_access_key, region, endpoint_url
            Write-Output $Config
        }
    }
}

function ConvertTo-AwsConfigFile {
    [CmdletBinding()]

    PARAM (
        [parameter(
            Mandatory=$True,
            Position=0,
            HelpMessage="Config to store in config file")][PSObject[]]$Config,
        [parameter(
            Mandatory=$True,
            Position=1,
            HelpMessage="AWS Config File")][String]$AwsConfigFile
    )

    Process {
        if (!(Test-Path $AwsConfigFile)) {
            New-Item -Path $AwsConfigFile -ItemType File -Force
        }
        $Output = ""
        if ($AwsConfigFile -match "credentials$")
        {
            foreach ($ConfigEntry in $Config) {
                $Output += "[$( $ConfigEntry.Profile )]`n"
                $Output += "aws_access_key_id = $($ConfigEntry.aws_access_key_id)`n"
                $Output += "aws_secret_access_key = $($ConfigEntry.aws_secret_access_key)`n"
            }
        }
        else {
            foreach ($ConfigEntry in $Config) {
                if ($ConfigEntry.Profile -eq "default")
                {
                    $Output += "[$( $ConfigEntry.Profile )]`n"
                }
                else
                {
                    $Output += "[profile $( $ConfigEntry.Profile )]`n"
                }
                $Properties = $Config | Select-Object -ExcludeProperty aws_access_key_id, aws_secret_access_key, profile | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
                foreach ($Property in $Properties)
                {
                    if ($ConfigEntry.$Property)
                    {
                        $Output += "$Property = $( $ConfigEntry.$Property )`n"
                    }
                }
            }
        }
        Write-Debug "Output:`n$Output"
        $Output | Out-File -FilePath $AwsConfigFile -NoNewline
    }
}

### AWS Cmdlets ###

<#
    .SYNOPSIS
    Retrieve SHA256 Hash for Payload
    .DESCRIPTION
    Retrieve SHA256 Hash for Payload
#>
function Global:Get-AwsHash {
    [CmdletBinding(DefaultParameterSetName="string")]

    PARAM (
        [parameter(
            Mandatory=$False,
            Position=0,
            ParameterSetName="string",
            HelpMessage="String to hash")][String]$StringToHash="",
        [parameter(
            Mandatory=$True,
            Position=1,
            ParameterSetName="file",
            HelpMessage="File to hash")][System.IO.FileInfo]$FileToHash
    )
 
    Process {
        $Hasher = [System.Security.Cryptography.SHA256]::Create()

        if ($FileToHash) {
            $Hash = Get-FileHash -Algorithm SHA256 -Path $FileToHash | select -ExpandProperty Hash
        }
        else {
            $Hash = ([BitConverter]::ToString($Hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($StringToHash))) -replace '-','').ToLower()
        }

        Write-Output $Hash
    }
}

<#
    .SYNOPSIS
    Create AWS Authentication Signature Version 2 for Request
    .DESCRIPTION
    Create AWS Authentication Signature Version 2 for Request
#>
function Global:New-AwsSignatureV2 {
    [CmdletBinding()]

    PARAM (
        [parameter(
            Mandatory=$True,
            Position=0,
            HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
            Mandatory=$True,
            Position=1,
            HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
            Mandatory=$True,
            Position=2,
            HelpMessage="Endpoint hostname and optional port")][System.UriBuilder]$EndpointUrl,
        [parameter(
            Mandatory=$False,
            Position=3,
            HelpMessage="HTTP Request Method")][ValidateSet("OPTIONS","GET","HEAD","PUT","DELETE","TRACE","CONNECT")][String]$HTTPRequestMethod="GET",
        [parameter(
            Mandatory=$False,
            Position=4,
            HelpMessage="URI")][String]$Uri="/",
        [parameter(
            Mandatory=$False,
            Position=6,
            HelpMessage="Content MD5")][String]$ContentMD5="",
        [parameter(
            Mandatory=$False,
            Position=7,
            HelpMessage="Content Type")][String]$ContentType="",
        [parameter(
            Mandatory=$False,
            Position=8,
            HelpMessage="Date")][String]$DateTime,
        [parameter(
            Mandatory=$False,
            Position=9,
            HelpMessage="Headers")][Hashtable]$Headers=@{},
        [parameter(
            Mandatory=$False,
            Position=10,
            HelpMessage="Bucket")][String]$Bucket,
        [parameter(
            Mandatory=$False,
            Position=11,
            HelpMessage="Query String (unencoded)")][String]$QueryString
    )
 
    Process {
        # this Cmdlet follows the steps outlined in https://docs.aws.amazon.com/AmazonS3/latest/dev/RESTAuthentication.html

        # initialization
        if (!$DateTime) {
            $DateTime = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")        
        }

        Write-Debug "Task 1: Constructing the CanonicalizedResource Element "

        $CanonicalizedResource = ""
        Write-Debug "1. Start with an empty string:`n$CanonicalizedResource"

        if ($Bucket -and $EndpointUrl.Host -match "^$Bucket") {
            $CanonicalizedResource += "/$Bucket"
            Write-Debug "2. Add the bucketname for virtual host style:`n$CanonicalizedResource" 
        }
        else {
            Write-Debug "2. Bucketname already part of Url for path style therefore skipping this step"
        }

        $CanonicalizedResource += $Uri
        Write-Debug "3. Append the path part of the un-decoded HTTP Request-URI, up-to but not including the query string:`n$CanonicalizedResource" 

        $CanonicalizedResource += $QueryString
        Write-Debug "4. Append the query string unencoded for signing:`n$CanonicalizedResource" 

        Write-Debug "Task 2: Constructing the CanonicalizedAmzHeaders Element"

        Write-Debug "1. Filter for all headers starting with x-amz"
        $AmzHeaders = $Headers.Clone()
        # remove all headers which do not start with x-amz
        $Headers.Keys | % { if ($_ -notmatch "x-amz") { $AmzHeaders.Remove($_) } }
        
        Write-Debug "2. Sort headers lexicographically"
        $SortedAmzHeaders = ConvertTo-SortedDictionary $AmzHeaders
        $CanonicalizedAmzHeaders = ($SortedAmzHeaders.GetEnumerator()  | % { "$($_.Key.toLower()):$($_.Value)" }) -join "`n"
        if ($CanonicalizedAmzHeaders) {
            $CanonicalizedAmzHeaders = $CanonicalizedAmzHeaders + "`n"
        }
        Write-Debug "3. CanonicalizedAmzHeaders headers:`n$CanonicalizedAmzHeaders"

        Write-Debug "Task 3: String to sign"

        $StringToSign = "$HTTPRequestMethod`n$ContentMD5`n$ContentType`n$DateTime`n$CanonicalizedAmzHeaders$CanonicalizedResource"

        Write-Debug "1. StringToSign:`n$StringToSign"

        Write-Debug "Task 4: Signature"

        $SignedString = Get-SignedString -Key ([Text.Encoding]::UTF8.GetBytes($SecretAccessKey)) -Message $StringToSign -Algorithm SHA1
        $Signature = [Convert]::ToBase64String($SignedString)

        Write-Debug "1. Signature:`n$Signature" 

        Write-Output $Signature
    }
}

<#
    .SYNOPSIS
    Create AWS Authentication Signature Version 4 for Request
    .DESCRIPTION
    Create AWS Authentication Signature Version 4 for Request
#>
function Global:New-AwsSignatureV4 {
    [CmdletBinding()]

    PARAM (
        [parameter(
            Mandatory=$True,
            Position=0,
            HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
            Mandatory=$True,
            Position=1,
            HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
            Mandatory=$True,
            Position=2,
            HelpMessage="Endpoint hostname and optional port")][System.UriBuilder]$EndpointUrl,
        [parameter(
            Mandatory=$False,
            Position=3,
            HelpMessage="HTTP Request Method")][ValidateSet("OPTIONS","GET","HEAD","PUT","DELETE","TRACE","CONNECT")][String]$HTTPRequestMethod="GET",
        [parameter(
            Mandatory=$False,
            Position=4,
            HelpMessage="URI")][String]$Uri="/",
        [parameter(
            Mandatory=$False,
            Position=5,
            HelpMessage="Canonical Query String")][String]$CanonicalQueryString,
        [parameter(
            Mandatory=$False,
            Position=6,
            HelpMessage="Date Time (yyyyMMddTHHmmssZ)")][String]$DateTime,
        [parameter(
            Mandatory=$False,
            Position=7,
            HelpMessage="Date String (yyyyMMdd)")][String]$DateString,
        [parameter(
            Mandatory=$False,
            Position=8,
            HelpMessage="Request payload hash")][String]$RequestPayloadHash,
        [parameter(
            Mandatory=$False,
            Position=9,
            HelpMessage="Region")][String]$Region,
        [parameter(
            Mandatory=$False,
            Position=10,
            HelpMessage="Region")][String]$Service="s3",
        [parameter(
            Mandatory=$False,
            Position=11,
            HelpMessage="Headers")][Hashtable]$Headers=@{},
        [parameter(
            Mandatory=$False,
            Position=12,
            HelpMessage="Content type")][String]$ContentType
    )

    Process {
        # this Cmdlet follows the steps outlined in http://docs.aws.amazon.com/general/latest/gr/sigv4_signing.html

        # initialization
        if (!$RequestPayloadHash) {
            $RequestPayloadHash = Get-AwsHash -StringToHash ""
        }
        if (!$DateTime) {
            $DateTime = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")        
        }
        if (!$DateString) {
            $DateString = [DateTime]::UtcNow.ToString('yyyyMMdd')
        }

        Write-Debug "Task 1: Create a Canonical Request for Signature Version 4"
        # http://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html

        Write-Debug "1. HTTP Request Method:`n$HTTPRequestMethod" 

        # only URL encode if service is not S3
        if ($Service -ne "s3" -and $Uri -ne "/") {
            $CanonicalURI = [System.Web.HttpUtility]::UrlEncode($Uri)
        }
        else {
            $CanonicalURI = $Uri
        }
        Write-Debug "2. Canonical URI:`n$CanonicalURI"

        Write-Debug "3. Canonical query string:`n$CanonicalQueryString"

        if (!$Headers["host"]) { $Headers["host"] = $EndpointUrl.Uri.Authority }
        if (!$Headers["x-amz-date"]) { $Headers["x-amz-date"] = $DateTime }
        if (!$Headers["content-type"] -and $ContentType) { $Headers["content-type"] = $ContentType }
        $SortedHeaders = ConvertTo-SortedDictionary $Headers
        $CanonicalHeaders = (($SortedHeaders.GetEnumerator()  | % { "$($_.Key.toLower()):$($_.Value)" }) -join "`n") + "`n"
        Write-Debug "4. Canonical headers:`n$CanonicalHeaders"

        $SignedHeaders = $SortedHeaders.Keys -join ";"
        Write-Debug "5. Signed headers:`n$SignedHeaders"

        Write-Debug "6. Hashed Payload`n$RequestPayloadHash"

        $CanonicalRequest = "$HTTPRequestMethod`n$CanonicalURI`n$CanonicalQueryString`n$CanonicalHeaders`n$SignedHeaders`n$RequestPayloadHash"
        Write-Debug "7. CanonicalRequest:`n$CanonicalRequest"

        $hasher = [System.Security.Cryptography.SHA256]::Create()
        $CanonicalRequestHash = ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($CanonicalRequest))) -replace '-','').ToLower()
        Write-Debug "8. Canonical request hash:`n$CanonicalRequestHash"

        Write-Debug "Task 2: Create a String to Sign for Signature Version 4"
        # http://docs.aws.amazon.com/general/latest/gr/sigv4-create-string-to-sign.html

        $AlgorithmDesignation = "AWS4-HMAC-SHA256"
        Write-Debug "1. Algorithm designation:`n$AlgorithmDesignation"

        Write-Debug "2. request date value, specified with ISO8601 basic format in the format YYYYMMDD'T'HHMMSS'Z:`n$DateTime"

        $CredentialScope = "$DateString/$Region/$Service/aws4_request"
        Write-Debug "3. Credential scope:`n$CredentialScope"

        Write-Debug "4. Canonical request hash:`n$CanonicalRequestHash"

        $StringToSign = "$AlgorithmDesignation`n$DateTime`n$CredentialScope`n$CanonicalRequestHash"
        Write-Debug "StringToSign:`n$StringToSign"

        Write-Debug "Task 3: Calculate the Signature for AWS Signature Version 4"
        # http://docs.aws.amazon.com/general/latest/gr/sigv4-calculate-signature.html

        $SigningKey = GetSignatureKey $SecretAccessKey $DateString $Region $Service
        Write-Debug "1. Signing Key:`n$([System.BitConverter]::ToString($SigningKey))"

        $Signature = ([BitConverter]::ToString((sign $SigningKey $StringToSign)) -replace '-','').ToLower()
        Write-Debug "2. Signature:`n$Signature"

        Write-Output $Signature
    }
}

<#
    .SYNOPSIS
    Invoke AWS Request
    .DESCRIPTION
    Invoke AWS Request
#>
function Global:Invoke-AwsRequest {
    [CmdletBinding(DefaultParameterSetName="none")]

    PARAM (
        [parameter(
            ParameterSetName="profile",
            Mandatory=$True,
            Position=0,
            HelpMessage="AWS Profile to use which contains AWS sredentials and settings")][String]$Profile,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=0,
            HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=1,
            HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
            ParameterSetName="account",
            Mandatory=$False,
            Position=0,
            HelpMessage="Account ID")][String]$AccountId,
        [parameter(
            Mandatory=$False,
            Position=2,
            HelpMessage="HTTP Request Method")][ValidateSet("OPTIONS","GET","HEAD","PUT","DELETE","TRACE","CONNECT")][String]$HTTPRequestMethod="GET",
        [parameter(
            Mandatory=$False,
            Position=3,
            HelpMessage="Endpoint URL")][System.UriBuilder]$EndpointUrl,
        [parameter(
            Mandatory=$False,
            Position=4,
            HelpMessage="URL Style")][String][ValidateSet("path","virtual-hosted")]$UrlStyle="path",
         [parameter(
            Mandatory=$False,
            Position=5,
            HelpMessage="Skip SSL Certificate check")][Switch]$SkipCertificateCheck,
        [parameter(
            Mandatory=$False,
            Position=6,
            HelpMessage="URI")][String]$Uri="/",
        [parameter(
            Mandatory=$False,
            Position=7,
            HelpMessage="Query String")][Hashtable]$Query,
        [parameter(
            Mandatory=$False,
            Position=8,
            HelpMessage="Request payload")][String]$RequestPayload="",
        [parameter(
            Mandatory=$False,
            Position=9,
            HelpMessage="Region")][String]$Region,
        [parameter(
            Mandatory=$False,
            Position=10,
            HelpMessage="Service")][String]$Service="s3",
        [parameter(
            Mandatory=$False,
            Position=11,
            HelpMessage="AWS Signer type (S3 for V2 Authentication and AWS4 for V4 Authentication)")][String][ValidateSet("S3","AWS4")]$SingerType="AWS4",
        [parameter(
            Mandatory=$False,
            Position=12,
            HelpMessage="Headers")][Hashtable]$Headers=@{},
        [parameter(
            Mandatory=$False,
            Position=13,
            HelpMessage="Content type")][String]$ContentType,
        [parameter(
            Mandatory=$False,
            Position=14,
            HelpMessage="Path where output should be saved to")][String]$FilePath,
        [parameter(
            Mandatory=$False,
            Position=15,
            HelpMessage="Bucket name")][String]$Bucket,
        [parameter(
            Mandatory=$False,
            Position=16,
            HelpMessage="File to output result to")][System.IO.DirectoryInfo]$OutFile,
        [parameter(
            Mandatory=$False,
            Position=17,
            HelpMessage="File to read data from")][System.IO.FileInfo]$InFile
    )

    Begin {
        $Credential = $null
        # convenience method to autogenerate credentials
        Write-Verbose "Account ID: $AccountId"
        if (!$Profile -and !$AccessKey -and $CurrentSgwServer -and !$CurrentSgwServer.DisableAutomaticAccessKeyGeneration) {
            if ($CurrentSgwServer.AccountId -and ($EndpointUrl -or $CurrentSgwServer.S3EndpointUrl)) {
                Write-Verbose "No profile and no access key specified, but connected to a StorageGRID tenant. Therefore using autogenerated temporary AWS credentials"
                if ($CurrentSgwServer.AccessKeyStore[$CurrentSgwServer.AccountId].expires -ge (Get-Date).ToUniversalTime().AddMinutes(1) -or ($CurrentSgwServer.AccessKeyStore[$CurrentSgwServer.AccountId] -and !$CurrentSgwServer.AccessKeyStore[$CurrentSgwServer.AccountId].expires)) {
                    $Credential = $CurrentSgwServer.AccessKeyStore[$CurrentSgwServer.AccountId] | Sort-Object -Property expires | Select-Object -Last 1
                    Write-Verbose "Using existing Access Key $($Credential.AccessKey)"
                }
                else {
                    $Credential = New-SgwS3AccessKey -Expires (Get-Date).AddSeconds($CurrentSgwServer.TemporaryAccessKeyExpirationTime)
                    Write-Verbose "Created new temporary Access Key $($Credential.AccessKey)"
                }
            }
            elseif ($AccountId) {
                Write-Verbose "No profile and no access key specified, but connected to a StorageGRID server. Therefore using autogenerated temporary AWS credentials for account ID $AccountId and removing them after command execution"
                if ($CurrentSgwServer.AccessKeyStore[$AccountId].expires -ge (Get-Date).ToUniversalTime().AddMinutes(1) -or ($CurrentSgwServer.AccessKeyStore[$AccountId] -and !$CurrentSgwServer.AccessKeyStore[$AccountId].expires)) {
                    $Credential = $CurrentSgwServer.AccessKeyStore[$AccountId] | Sort-Object -Property expires | Select-Object -Last 1
                    Write-Verbose "Using existing Access Key $($Credential.AccessKey)"
                }
                else {
                    $Credential = New-SgwS3AccessKey -AccountId $AccountId -Expires (Get-Date).AddSeconds($CurrentSgwServer.TemporaryAccessKeyExpirationTime)
                    Write-Verbose "Created new temporary Access Key $($Credential.AccessKey)"
                }
            }
            elseif ($Bucket -and $CurrentSgwServer.SupportedApiVersions.Contains(1) -and !$CurrentSgwServer.AccountId) {
                # need to check each account for its buckets to determine which account the bucket belongs to
                $AccountId = foreach ($Account in (Get-SgwAccounts)) {
                    if ($Account | Get-SgwAccountUsage | select -ExpandProperty buckets | ? { $_.name -eq $Bucket }) {
                        Write-Output $Account.id
                        break
                    }
                }
                if ($AccountId) {
                    Write-Verbose "No profile and no access key specified, therefore using autogenerated temporary AWS credentials and removing them after command execution"
                    if ($CurrentSgwServer.AccessKeyStore[$AccountId].expires -ge (Get-Date).ToUniversalTime().AddMinutes(1) -or ($CurrentSgwServer.AccessKeyStore[$AccountId] -and !$CurrentSgwServer.AccessKeyStore[$AccountId].expires)) {
                        $Credential = $CurrentSgwServer.AccessKeyStore[$AccountId] | Sort-Object -Property expires | Select-Object -Last 1
                        Write-Verbose "Using existing Access Key $($Credential.AccessKey)"
                    }
                    else {
                        $Credential = New-SgwS3AccessKey -AccountId $AccountId -Expires (Get-Date).AddSeconds($CurrentSgwServer.TemporaryAccessKeyExpirationTime)
                        Write-Verbose "Created new temporary Access Key $($Credential.AccessKey)"
                    }
                }
                else {
                    $Profile = "default"
                }
            }
            else {
                Write-Verbose "StorageGRID Server present, but either API Version 1 is not supported or no EndpointUrl available"
                $Profile = "default"            
            }

            if ($Credential -and !$EndpointUrl -and $CurrentSgwServer.S3EndpointUrl) {
                Write-Verbose "EndpointUrl not specified, but discovered S3 Endpoint $($CurrentSgwServer.S3EndpointUrl) from StorageGRID Server"
                $EndpointUrl = [System.UriBuilder]$CurrentSgwServer.S3EndpointUrl
                if ($CurrentSgwServer.SkipCertificateCheck) {
                    $SkipCertificateCheck = $True
                }
            }

            if ($Credential -and $EndpointUrl) {
                $AccessKey = $Credential.accessKey
                $SecretAccessKey = $Credential.secretAccessKey
            }
            elseif ($Credential) {
                $Profile = "default"
            }
        }

        if (!$Credential -and !$AccessKey -and !$Profile) {
            $Profile = "default"
        }
        
        if ($Profile -and !$AccessKey) {
            Write-Verbose "Using credentials from profile $Profile"
            if (!(Test-Path $AWS_CREDENTIALS_FILE)) {
                throw "Profile $Profile does not contain credentials. Either connect to a StorageGRID Server using Connect-SgwServer or add credentials to the default profile with Add-AwsCredentials"
            }
            $Credential = Get-AwsCredential -Profile $Profile
            $AccessKey = $Credential.aws_access_key_id
            $SecretAccessKey = $Credential.aws_secret_access_key

            if (!$Region) {
                $Config = ConvertFrom-AwsConfigFile -AwsConfigFile $AWS_CONFIG_FILE
                $Region = $Config[$Profile].region
            }
        }

        if (!$Region) {
            $Region = "us-east-1"
        }

        if (!$AccessKey) {
            throw "No Access Key specified"
        }
        if (!$SecretAccessKey) {
            throw "No Secret Access Key specified"
        }

        if ([environment]::OSVersion.Platform -match "Win") {
            # check if proxy is used
            $ProxyRegistry = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
            $ProxySettings = Get-ItemProperty -Path $ProxyRegistry
            if ($ProxySettings.ProxyEnable) {
                Write-Warning "Proxy Server $($ProxySettings.ProxyServer) configured in Internet Explorer may be used to connect to the endpoint!"
            }
            if ($ProxySettings.AutoConfigURL) {
                Write-Warning "Proxy Server defined in automatic proxy configuration script $($ProxySettings.AutoConfigURL) configured in Internet Explorer may be used to connect to the endpoint!"
            }
        }

        if (!$EndpointUrl) {
            if ($Region -eq "us-east-1" -or !$Region) {
                $EndpointUrl = [System.UriBuilder]::new("https://s3.amazonaws.com")
            }
            else {
                $EndpointUrl = [System.UriBuilder]::new("https://s3.$Region.amazonaws.com")
            }
        }

        if ($UrlStyle -eq "virtual-hosted" -and $Bucket) {
            Write-Verbose "Using virtual-hosted style URL"
            $EndpointUrl.host = $Bucket + '.' + $EndpointUrl.host
        }
        elseif ($Bucket) {
            Write-Verbose "Using path style URL"
            $Uri = "/$Bucket" + $Uri
        }
    }
 
    Process {        
        $DateTime = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
        $DateString = [DateTime]::UtcNow.ToString('yyyyMMdd')

        $QueryString = ""
        $CanonicalQueryString = ""
        if ($Query.Keys.Count -ge 1) {
            # using Sorted Dictionary as query need to be sorted by encoded keys
            $SortedQuery = New-Object 'System.Collections.Generic.SortedDictionary[string, string]'
            
            foreach ($Key in $Query.Keys) {
                # Key and value need to be URL encoded separately
                $SortedQuery[$Key]=$Query[$Key]
            }
            foreach ($Key in $SortedQuery.Keys) {
                # AWS V2 only requires specific queries to be included in signing process                
                if ($Key -match "versioning|location|acl|torrent|lifecycle|versionid|response-content-type|response-content-language|response-expires|response-cache-control|response-content-disposition|response-content-encoding") {
                    $QueryString += "$Key=$($SortedQuery[$Key])&"
                }
                $CanonicalQueryString += "$([System.Web.HttpUtility]::UrlEncode($Key))=$([System.Web.HttpUtility]::UrlEncode($SortedQuery[$Key]))&"
            }
            $QueryString = $QueryString -replace "&`$",""
            $CanonicalQueryString = $CanonicalQueryString -replace "&`$",""
        }

        if ($InFile) {
            $RequestPayloadHash=Get-AWSHash -FileToHash $InFile
        }
        else {
            $RequestPayloadHash=Get-AWSHash -StringToHash $RequestPayload
        }
        
        if (!$Headers["host"]) { $Headers["host"] = $EndpointUrl.Uri.Authority }
        if (!$Headers["x-amz-content-sha256"]) { $Headers["x-amz-content-sha256"] = $RequestPayloadHash }
        if (!$Headers["x-amz-date"]) { $Headers["x-amz-date"] = $DateTime }
        if (!$Headers["content-type"] -and $ContentType) { $Headers["content-type"] = $ContentType }

        $SortedHeaders = ConvertTo-SortedDictionary $Headers

        $SignedHeaders = $SortedHeaders.Keys -join ";"

        if ($SingerType = "AWS4") {
            Write-Verbose "Using AWS Signature Version 4"
            $Signature = New-AwsSignatureV4 -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -EndpointUrl $EndpointUrl -Region $Region -Uri $Uri -CanonicalQueryString $CanonicalQueryString -HTTPRequestMethod $HTTPRequestMethod -RequestPayloadHash $RequestPayloadHash -DateTime $DateTime -DateString $DateString -Headers $Headers
            Write-Debug "Task 4: Add the Signing Information to the Request"
            # http://docs.aws.amazon.com/general/latest/gr/sigv4-add-signature-to-request.html
            $Headers["Authorization"]="AWS4-HMAC-SHA256 Credential=$AccessKey/$DateString/$Region/$Service/aws4_request,SignedHeaders=$SignedHeaders,Signature=$Signature"
            Write-Debug "Headers:`n$(ConvertTo-Json -InputObject $Headers)"
        }
        else {
            Write-Verbose "Using AWS Signature Version 2"
            $Signature = New-AwsSignatureV2 -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -EndpointUrl $EndpointUrl -Uri $Uri -HTTPRequestMethod $HTTPRequestMethod -ContentMD5 $ContentMd5 -ContentType $ContentType -Date $DateTime -Bucket $Bucket -QueryString $QueryString
        }

        $EndpointUrl.Path = $Uri
        $EndpointUrl.Query = $CanonicalQueryString

        # check if untrusted SSL certificates should be ignored
        if ($SkipCertificateCheck) {
            if ($PSVersionTable.PSVersion.Major -lt 6) {
                [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
            }
            else {
                if (!"Invoke-WebRequest:SkipCertificateCheck") {
                    $PSDefaultParameterValues.Add("Invoke-WebRequest:SkipCertificateCheck",$true)
                }
                else {
                    $PSDefaultParameterValues.'Invoke-WebRequest:SkipCertificateCheck'=$true
                }
            }
        }
        else {
            # currently there is no way to re-enable certificate check for the current session in PowerShell prior to version 6
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                if ("Invoke-WebRequest:SkipCertificateCheck") {
                    $PSDefaultParameterValues.Remove("Invoke-WebRequest:SkipCertificateCheck")
                }
            }
        }

        try {
            # PowerShell 5 and early cannot skip certificate validation per request therefore we need to use a workaround
            if ($PSVersionTable.PSVersion.Major -lt 6 ) {
                if ($SkipCertificateCheck.isPresent) {
                    $CurrentCertificatePolicy = [System.Net.ServicePointManager]::CertificatePolicy
                    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
                }
                if ($RequestPayload) {
                    if ($OutFile) {
                        Write-Verbose "RequestPayload:`n$RequestPayload"
                        Write-Verbose "Saving output in file $OutFile"
                        $Result = Invoke-WebRequest -Method $HTTPRequestMethod -Uri $EndpointUrl.Uri -Headers $Headers -Body $RequestPayload -OutFile $OutFile
                    }
                    else {
                        Write-Verbose "RequestPayload:`n$RequestPayload"
                        $Result = Invoke-WebRequest -Method $HTTPRequestMethod -Uri $EndpointUrl.Uri -Headers $Headers -Body $RequestPayload
                    }
                }
                else {
                    if ($OutFile) {
                        Write-Verbose "Saving output in file $OutFile"
                        $Result = Invoke-WebRequest -Method $HTTPRequestMethod -Uri $EndpointUrl.Uri -Headers $Headers -OutFile $OutFile
                    }
                    elseif ($InFile) {
                        Write-Verbose "InFile:`n$InFile"
                        $Result = Invoke-WebRequest -Method $HTTPRequestMethod -Uri $EndpointUrl.Uri -Headers $Headers -InFile $InFile
                    }
                    else {
                        $Result = Invoke-WebRequest -Method $HTTPRequestMethod -Uri $EndpointUrl.Uri -Headers $Headers
                    }
                }
                if ($SkipCertificateCheck.isPresent) {
                    [System.Net.ServicePointManager]::CertificatePolicy = $CurrentCertificatePolicy
                }
            }
            else {
                if ($RequestPayload) {
                    if ($OutFile) {
                        Write-Verbose "RequestPayload:`n$RequestPayload"
                        Write-Verbose "Saving output in file $OutFile"
                        $Result = Invoke-WebRequest -Method $HTTPRequestMethod -Uri $EndpointUrl.Uri -Headers $Headers -Body $RequestPayload -OutFile $OutFile -SkipCertificateCheck:$SkipCertificateCheck
                    }
                    else {
                        Write-Verbose "RequestPayload:`n$RequestPayload"
                        $Result = Invoke-WebRequest -Method $HTTPRequestMethod -Uri $EndpointUrl.Uri -Headers $Headers -Body $RequestPayload -SkipCertificateCheck:$SkipCertificateCheck
                    }
                }
                else {
                    if ($OutFile) {
                        Write-Verbose "Saving output in file $OutFile"
                        $Result = Invoke-WebRequest -Method $HTTPRequestMethod -Uri $EndpointUrl.Uri -Headers $Headers -OutFile $OutFile -SkipCertificateCheck:$SkipCertificateCheck
                    }
                    elseif ($InFile) {
                        Write-Verbose "InFile:`n$InFile"
                        $Result = Invoke-WebRequest -Method $HTTPRequestMethod -Uri $EndpointUrl.Uri -Headers $Headers -InFile $InFile -SkipCertificateCheck:$SkipCertificateCheck
                    }
                    else {
                        Write-Verbose "URI:$($EndpointUrl.Uri)"
                        Write-Verbose "Headers:$($Headers | ConvertTo-Json)"
                        $Result = Invoke-WebRequest -Method $HTTPRequestMethod -Uri $EndpointUrl.Uri -Headers $Headers -SkipCertificateCheck:$SkipCertificateCheck
                    }
                }
            }
        }
        catch {
            $ResponseBody = ParseErrorForResponseBody $_
            Write-Error "$HTTPRequestMethod to $EndpointUrl failed with Exception $($_.Exception.Message) `n $ResponseBody"
        }

        Write-Output $Result
    }
}

Set-Alias -Name Set-AwsCredentials -Value Add-AwsConfig
Set-Alias -Name New-AwsCredentials -Value Add-AwsConfig
Set-Alias -Name Add-AwsCredentials -Value Add-AwsConfig
Set-Alias -Name Update-AwsCredentials -Value Add-AwsConfig
Set-Alias -Name Set-AwsConfig -Value Add-AwsConfig
Set-Alias -Name New-AwsConfig -Value Add-AwsConfig
Set-Alias -Name Update-AwsConfig -Value Add-AwsConfig
<#
    .SYNOPSIS
    Add AWS Credentials
    .DESCRIPTION
    Add AWS Credentials
#>
function Global:Add-AwsConfig {
    [CmdletBinding(DefaultParameterSetName="credential")]

    PARAM (
        [parameter(
            Mandatory=$False,
            Position=0,
            HelpMessage="AWS Profile to use which contains AWS sredentials and settings")][String]$Profile="default",
        [parameter(
            ParameterSetName="credential",
            Mandatory=$True,
            Position=1,
            HelpMessage="Credential")][PSCredential]$Credential,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$True,
            Position=1,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="S3 Access Key")][Alias("aws_access_key_id")][String]$AccessKey,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$True,
            Position=2,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="S3 Secret Access Key")][Alias("aws_secret_access_key")][String]$SecretAccessKey,
        [parameter(
            Mandatory=$False,
            Position=3,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Default Region to use for all requests made with these credentials")][String]$Region,
        [parameter(
            Mandatory=$False,
            Position=4,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Custom endpoint URL if different than AWS URL")][Alias("endpoint_url")][System.UriBuilder]$EndpointUrl
    )
 
    Process {
        if ($Credential) {
            $AccessKey = $Credential.UserName
            $SecretAccessKey = $Credential.GetNetworkCredential().Password
        }

        if ($AccessKey -and $SecretAccessKey) {
            $Credentials = ConvertFrom-AwsConfigFile -AwsConfigFile $AWS_CREDENTIALS_FILE
            if (($Credentials | Where-Object { $_.profile -eq $Profile})) {
                $CredentialEntry = $Credentials | Where-Object { $_.profile -eq $Profile}
            }
            else {
                $CredentialEntry = [PSCustomObject]@{ profile = $Profile }
            }

            $CredentialEntry | Add-Member -MemberType NoteProperty -Name aws_access_key_id -Value $AccessKey -Force
            $CredentialEntry | Add-Member -MemberType NoteProperty -Name aws_secret_access_key -Value $SecretAccessKey -Force

            Write-Debug $CredentialEntry

            $Credentials = @($Credentials | Where-Object { $_.profile -ne $Profile}) + $CredentialEntry
            ConvertTo-AwsConfigFile -Config $Credentials -AwsConfigFile $AWS_CREDENTIALS_FILE
        }

        if ($Region -or $EndpointUrl) {
            $Config = ConvertFrom-AwsConfigFile -AwsConfigFile $AWS_CONFIG_FILE

            if (($Config | Where-Object { $_.profile -eq $Profile})) {
                $ConfigEntry = $Config | Where-Object { $_.profile -eq $Profile}
            }
            else {
                $ConfigEntry = [PSCustomObject]@{ profile = $Profile }
            }

            if ($Region) {
                $ConfigEntry | Add-Member -MemberType NoteProperty -Name region -Value $Region -Force
            }
            if ($EndpointUrl) {
                $ConfigEntry | Add-Member -MemberType NoteProperty -Name endpoint_url -Value $EndpointUrl -Force
            }

            $Config = @($Config | Where-Object { $_.profile -ne $Profile}) + $ConfigEntry
            ConvertTo-AwsConfigFile -Config $Config -AwsConfigFile $AWS_CONFIG_FILE
        }
    }
}

Set-Alias -Name Get-AwsCredential -Value Get-AwsConfig
Set-Alias -Name Get-AwsCredentials -Value Get-AwsConfig
<#
    .SYNOPSIS
    Get AWS Config
    .DESCRIPTION
    Get AWS Config
#>
function Global:Get-AwsConfig {
    [CmdletBinding()]

    PARAM (
        [parameter(
                Mandatory=$False,
                Position=0,
                HelpMessage="AWS Profile to use which contains AWS sredentials and settings")][String]$Profile
    )

    Process {
        $Credentials = @()
        $Config = @()
        try {
            $Credentials = ConvertFrom-AwsConfigFile -AwsConfigFile $AWS_CREDENTIALS_FILE
        }
        catch {
            Write-Verbose "Retrieving credentials from $AWS_CREDENTIALS_FILE failed"
        }
        try {
            $Config = ConvertFrom-AwsConfigFile -AwsConfigFile $AWS_CONFIG_FILE
        }
        catch {
            Write-Verbose "Retrieving credentials from $AWS_CONFIG_FILE failed"
        }

        foreach ($Credential in $Credentials) {
            $ConfigEntry = $Config | Where-Object { $_.Profile -eq $Credential.Profile } | Select-Object -First 1
            if ($ConfigEntry) {
                $ConfigEntry.aws_access_key_id = $Credential.aws_access_key_id
                $ConfigEntry.aws_secret_access_key = $Credential.aws_secret_access_key
            }
            else {
                $Config = @($Config) + ([PSCustomObject]@{profile=$Credential.profile;aws_access_key_id=$Credential.aws_access_key_id;aws_secret_access_key=$Credential.aws_secret_access_key;region="";endpoint_url=$null})
            }
        }
        if ($Profile) {
            Write-Output $Config | Where-Object { $_.Profile -eq $Profile }
        }
        else {
            Write-Output $Config
        }

    }
}

<#
    .SYNOPSIS
    Remove AWS Config
    .DESCRIPTION
    Remove AWS Config
#>
function Global:Remove-AwsConfig {
    [CmdletBinding()]

    PARAM (
        [parameter(
                Mandatory=$True,
                Position=0,
                HelpMessage="AWS Profile where config should be removed")][String]$Profile
    )

    Process {
        $Credentials = ConvertFrom-AwsConfigFile -AwsConfigFile $AWS_CREDENTIALS_FILE
        $Credentials = $Credentials | Where-Object { $_.Profile -ne $Profile }
        ConvertTo-AwsConfigFile -Config $Credentials -AwsConfigFile $AWS_CREDENTIALS_FILE

        $Config = ConvertFrom-AwsConfigFile -AwsConfigFile $AWS_CONFIG_FILE
        $Config = $Credentials | Where-Object { $_.Profile -ne $Profile }
        ConvertTo-AwsConfigFile -Config $Config -AwsConfigFile $AWS_CONFIG_FILE
    }
}


### S3 Cmdlets ###

## Buckets ##

<#
    .SYNOPSIS
    Get S3 Buckets
    .DESCRIPTION
    Get S3 Buckets
#>
function Global:Get-S3Buckets {
    [CmdletBinding(DefaultParameterSetName="none")]

    PARAM (
        [parameter(
            Mandatory=$False,
            Position=0,
            HelpMessage="EndpointUrl")][System.UriBuilder]$EndpointUrl,
        [parameter(
            Mandatory=$False,
            Position=1,
            HelpMessage="Skip SSL Certificate Check")][Switch]$SkipCertificateCheck,
        [parameter(
            ParameterSetName="profile",
            Mandatory=$False,
            Position=2,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="AWS Profile to use which contains AWS credentials and settings")][String]$Profile,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=2,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=3,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
            ParameterSetName="account",
            Mandatory=$False,
            Position=2,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="StorageGRID account ID to execute this command against")][String]$AccountId
    )
 
    Process {
        $Uri = '/'
        $HTTPRequestMethod = "GET"

        if ($Profile) {
            $Result = Invoke-AwsRequest -Profile $Profile -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Uri $Uri -SkipCertificateCheck:$SkipCertificateCheck -ErrorAction Stop
        }
        elseif ($AccessKey) {
            $Result = Invoke-AwsRequest -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Uri $Uri -SkipCertificateCheck:$SkipCertificateCheck -ErrorAction Stop
        }
        elseif ($AccountId) {
            $Result = Invoke-AwsRequest -AccountId $AccountId -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Uri $Uri -SkipCertificateCheck:$SkipCertificateCheck -ErrorAction Stop
        }
        else {
            if ($CurrentSgwServer.SupportedApiVersions -match "1" -and !$CurrentSgwServer.AccountId) {
                Get-SgwAccounts -Capabilities "s3" |  Get-S3Buckets -EndpointUrl $EndpointUrl -SkipCertificateCheck:$SkipCertificateCheck
            }
            else {
                $Result = Invoke-AwsRequest -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Uri $Uri -SkipCertificateCheck:$SkipCertificateCheck -ErrorAction Stop
            }
        }

        $Content = [XML]$Result.Content

        if ($Content.ListAllMyBucketsResult) {
            foreach ($Bucket in $Content.ListAllMyBucketsResult.Buckets.ChildNodes) {
                if ($Profile) {
                    $Location = Get-S3BucketLocation -EndpointUrl $EndpointUrl -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket.Name -Profile $Profile
                }
                elseif ($AccessKey) {
                    $Location = Get-S3BucketLocation -EndpointUrl $EndpointUrl -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket.Name -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey
                }
                elseif ($AccountId) {
                    $Location = Get-S3BucketLocation -EndpointUrl $EndpointUrl -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket.Name -AccountId $AccountId
                }
                else {
                    $AccountId = $Content.ListAllMyBucketsResult.Owner.ID
                    $Location = Get-S3BucketLocation -EndpointUrl $EndpointUrl -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket.Name -AccountId $AccountId
                }

                $Bucket = [PSCustomObject]@{ Name = $Bucket.Name; CreationDate = $Bucket.CreationDate; OwnerId = $Content.ListAllMyBucketsResult.Owner.ID; OwnerDisplayName = $Content.ListAllMyBucketsResult.Owner.DisplayName; Region = $Location }
                Write-Output $Bucket
            }
        }
    }
}

<#
    .SYNOPSIS
    Test S3 Bucket
    .DESCRIPTION
    Test S3 Bucket
#>
function Global:Test-S3Bucket {
    [CmdletBinding(DefaultParameterSetName="none")]

    PARAM (
        [parameter(
                ParameterSetName="profile",
                Mandatory=$False,
                Position=0,
                HelpMessage="AWS Profile to use which contains AWS sredentials and settings")][String]$Profile,
        [parameter(
                ParameterSetName="keys",
                Mandatory=$False,
                Position=0,
                HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
                ParameterSetName="keys",
                Mandatory=$False,
                Position=1,
                HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
                ParameterSetName="account",
                Mandatory=$False,
                Position=0,
                HelpMessage="StorageGRID account ID to execute this command against")][String]$AccountId,
        [parameter(
                Mandatory=$False,
                Position=2,
                HelpMessage="EndpointUrl")][System.UriBuilder]$EndpointUrl,
        [parameter(
                Mandatory=$False,
                Position=3,
                ValueFromPipeline=$True,
                ValueFromPipelineByPropertyName=$True,
                HelpMessage="Region to be used")][String]$Region,
        [parameter(
                Mandatory=$False,
                Position=4,
                HelpMessage="Skip SSL Certificate Check")][Switch]$SkipCertificateCheck,
        [parameter(
                Mandatory=$False,
                Position=5,
                HelpMessage="Path Style")][String][ValidateSet("path","virtual-hosted")]$UrlStyle="path",
        [parameter(
                Mandatory=$True,
                Position=6,
                ValueFromPipeline=$True,
                ValueFromPipelineByPropertyName=$True,
                HelpMessage="Bucket")][Alias("Name")][String]$Bucket

    )

    Process {
        $HTTPRequestMethod = "HEAD"

        if ($Profile) {
            $Result = Invoke-AwsRequest -Profile $Profile -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccessKey) {
            $Result = Invoke-AwsRequest -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccountId) {
            $Result = Invoke-AwsRequest -AccountId $AccountId -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }
        else {
            $Result = Invoke-AwsRequest -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }
    }
}

<#
    .SYNOPSIS
    Get S3 Bucket
    .DESCRIPTION
    Get S3 Bucket
#>
function Global:Get-S3Bucket {
    [CmdletBinding(DefaultParameterSetName="none")]

    PARAM (
        [parameter(
            ParameterSetName="profile",
            Mandatory=$False,
            Position=0,
            HelpMessage="AWS Profile to use which contains AWS sredentials and settings")][String]$Profile,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=0,
            HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=1,
            HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
            ParameterSetName="account",
            Mandatory=$False,
            Position=0,
            HelpMessage="StorageGRID account ID to execute this command against")][String]$AccountId,
        [parameter(
            Mandatory=$False,
            Position=2,
            HelpMessage="EndpointUrl")][System.UriBuilder]$EndpointUrl,
        [parameter(
            Mandatory=$False,
            Position=3,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Region to be used")][String]$Region,
        [parameter(
            Mandatory=$False,
            Position=4,
            HelpMessage="Skip SSL Certificate Check")][Switch]$SkipCertificateCheck,
        [parameter(
            Mandatory=$False,
            Position=5,
            HelpMessage="Path Style")][String][ValidateSet("path","virtual-hosted")]$UrlStyle="path",
        [parameter(
            Mandatory=$True,
            Position=6,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Bucket")][Alias("Name")][String]$Bucket,
        [parameter(
            Mandatory=$False,
            Position=7,
            HelpMessage="Maximum Number of keys to return")][Int][ValidateRange(0,1000)]$MaxKeys=0,
        [parameter(
            Mandatory=$False,
            Position=8,
            HelpMessage="Bucket prefix for filtering")][String]$Prefix,
        [parameter(
            Mandatory=$False,
            Position=9,
            HelpMessage="Bucket prefix for filtering")][String][ValidateLength(1,1)]$Delimiter,
        [parameter(
            Mandatory=$False,
            Position=10,
            HelpMessage="Return Owner information (Only valid for list type 2).")][Switch]$FetchOwner=$False,
        [parameter(
            Mandatory=$False,
            Position=11,
            HelpMessage="Return key names after a specific object key in your key space. The S3 service lists objects in UTF-8 character encoding in lexicographical order (Only valid for list type 2).")][String]$StartAfter,
        [parameter(
            Mandatory=$False,
            Position=12,
            HelpMessage="Continuation token (Only valid for list type 1).")][String]$Marker,
       [parameter(
            Mandatory=$False,
            Position=13,
            HelpMessage="Continuation token (Only valid for list type 2).")][String]$ContinuationToken,
        [parameter(
            Mandatory=$False,
            Position=14,
            HelpMessage="Encoding type (Only allowed value is url).")][String][ValidateSet("url")]$EncodingType,
        [parameter(
            Mandatory=$False,
            Position=15,
            HelpMessage="Bucket list type.")][String][ValidateSet(1,2)]$ListType=1

    )
 
    Process {
        $HTTPRequestMethod = "GET"

        $Query = @{}

        if ($Delimiter) { $Query["delimiter"] = $Delimiter }
        if ($EncodingType) { $Query["encoding-type"] = $EncodingType }
        if ($MaxKeys -ge 1) {
            $Query["max-keys"] = $MaxKeys
        }
        if ($Prefix) { $Query["prefix"] = $Prefix }

        # S3 supports two types for listing buckets, but only v2 is recommended, thus using list-type=2 query parameter
        if ($ListType -eq 1) {
            if ($Marker) { $Query["marker"] = $Marker }
        }
        else {
            $Query["list-type"] = 2
            if ($FetchOwner) { $Query["fetch-owner"] = $FetchOwner }
            if ($StartAfter) { $Query["start-after"] = $StartAfter }
            if ($ContinuationToken) { $Query["continuation-token"] = $ContinuationToken }
        }

        if ($Profile) {
            $Result = Invoke-AwsRequest -Profile $Profile -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccessKey) {
            $Result = Invoke-AwsRequest -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccountId) {
            $Result = Invoke-AwsRequest -AccountId $AccountId -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        else {
            $Result = Invoke-AwsRequest -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }

        $Content = [XML]$Result.Content

        $Objects = $Content.ListBucketResult.Contents | ? { $_ }
        $Objects | Add-Member -MemberType NoteProperty -Name Bucket -Value $Content.ListBucketResult.Name
        $Objects | Add-Member -MemberType NoteProperty -Name Region -Value $Region

        Write-Output $Objects

        if ($Content.ListBucketResult.IsTruncated -eq "true" -and $MaxKeys -eq 0) {
            Write-Verbose "1000 Objects were returned and max keys was not limited so continuing to get all objects"
            Write-Debug "NextMarker: $($Content.ListBucketResult.NextMarker)"
            if ($Profile) {
                Get-S3Bucket -Profile $Profile -EndpointUrl $EndpointUrl -Region $Region -SkipCertificateCheck:$SkipCertificateCheck -UrlStyle $UrlStyle -Bucket $Bucket -MaxKeys $MaxKeys -Prefix $Prefix -FetchOwner:$FetchOwner -StartAfter $StartAfter -ContinuationToken $Content.ListBucketResult.NextContinuationToken -Marker $Content.ListBucketResult.NextMarker
            }
            elseif ($AccessKey) {
                Get-S3Bucket -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -EndpointUrl $EndpointUrl -Region $Region -SkipCertificateCheck:$SkipCertificateCheck -UrlStyle $UrlStyle -Bucket $Bucket -MaxKeys $MaxKeys -Prefix $Prefix -FetchOwner:$FetchOwner -StartAfter $StartAfter -ContinuationToken $Content.ListBucketResult.NextContinuationToken -Marker $Content.ListBucketResult.NextMarker
            }
            elseif ($AccountId) {
                Get-S3Bucket -AccountId $AccountId -EndpointUrl $EndpointUrl -Region $Region -SkipCertificateCheck:$SkipCertificateCheck -UrlStyle $UrlStyle -Bucket $Bucket -MaxKeys $MaxKeys -Prefix $Prefix -FetchOwner:$FetchOwner -StartAfter $StartAfter -ContinuationToken $Content.ListBucketResult.NextContinuationToken -Marker $Content.ListBucketResult.NextMarker
            }
            else {
                Get-S3Bucket -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -EndpointUrl $EndpointUrl -Region $Region -SkipCertificateCheck:$SkipCertificateCheck -UrlStyle $UrlStyle -Bucket $Bucket -MaxKeys $MaxKeys -Prefix $Prefix -FetchOwner:$FetchOwner -StartAfter $StartAfter -ContinuationToken $Content.ListBucketResult.NextContinuationToken -Marker $Content.ListBucketResult.NextMarker
            }            
        }   
    }
}

Set-Alias -Name Get-S3ObjectVersions -Value Get-S3BucketVersions
<#
    .SYNOPSIS
    Get S3 Bucket
    .DESCRIPTION
    Get S3 Bucket
#>
function Global:Get-S3BucketVersions {
    [CmdletBinding(DefaultParameterSetName="none")]

    PARAM (
        [parameter(
                ParameterSetName="profile",
                Mandatory=$False,
                Position=0,
                HelpMessage="AWS Profile to use which contains AWS sredentials and settings")][String]$Profile,
        [parameter(
                ParameterSetName="keys",
                Mandatory=$False,
                Position=0,
                HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
                ParameterSetName="keys",
                Mandatory=$False,
                Position=1,
                HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
                ParameterSetName="account",
                Mandatory=$False,
                Position=0,
                HelpMessage="StorageGRID account ID to execute this command against")][String]$AccountId,
        [parameter(
                Mandatory=$False,
                Position=2,
                HelpMessage="EndpointUrl")][System.UriBuilder]$EndpointUrl,
        [parameter(
                Mandatory=$False,
                Position=3,
                ValueFromPipeline=$True,
                ValueFromPipelineByPropertyName=$True,
                HelpMessage="Region to be used")][String]$Region,
        [parameter(
                Mandatory=$False,
                Position=4,
                HelpMessage="Skip SSL Certificate Check")][Switch]$SkipCertificateCheck,
        [parameter(
                Mandatory=$False,
                Position=5,
                HelpMessage="Path Style")][String][ValidateSet("path","virtual-hosted")]$UrlStyle="path",
        [parameter(
                Mandatory=$True,
                Position=6,
                ValueFromPipeline=$True,
                ValueFromPipelineByPropertyName=$True,
                HelpMessage="Bucket")][Alias("Name")][String]$Bucket,
        [parameter(
                Mandatory=$False,
                Position=7,
                HelpMessage="Maximum Number of keys to return")][Int][ValidateRange(0,1000)]$MaxKeys=0,
        [parameter(
                Mandatory=$False,
                Position=8,
                HelpMessage="Bucket prefix for filtering")][String]$Prefix,
        [parameter(
                Mandatory=$False,
                Position=9,
                HelpMessage="Bucket prefix for filtering")][String][ValidateLength(1,1)]$Delimiter,
        [parameter(
                Mandatory=$False,
                Position=10,
                HelpMessage="Continuation token for keys.")][String]$KeyMarker,
        [parameter(
                Mandatory=$False,
                Position=11,
                HelpMessage="Continuation token for versions.")][String]$VersionIdMarker,
        [parameter(
                Mandatory=$False,
                Position=12,
                HelpMessage="Encoding type (Only allowed value is url).")][String][ValidateSet("url")]$EncodingType

    )

    Process {
        $HTTPRequestMethod = "GET"

        $Query = @{versions=""}

        if ($Delimiter) { $Query["delimiter"] = $Delimiter }
        if ($EncodingType) { $Query["encoding-type"] = $EncodingType }
        if ($MaxKeys -ge 1) {
            $Query["max-keys"] = $MaxKeys
        }
        if ($Prefix) { $Query["prefix"] = $Prefix }
        if ($KeyMarker) { $Query["key-marker"] = $KeyMarker }
        if ($VersionIdMarker) { $Query["version-id-marker"] = $VersionIdMarker }

        if ($Profile) {
            $Result = Invoke-AwsRequest -Profile $Profile -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccessKey) {
            $Result = Invoke-AwsRequest -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccountId) {
            $Result = Invoke-AwsRequest -AccountId $AccountId -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        else {
            $Result = Invoke-AwsRequest -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }

        $Content = [XML]$Result.Content

        $Versions = $Content.ListVersionsResult.Version | ? { $_ }
        $Versions | Add-Member -MemberType NoteProperty -Name Type -Value "Version"
        $DeleteMarkers = $Content.ListVersionsResult.DeleteMarker | ? { $_ }
        $DeleteMarkers | Add-Member -MemberType NoteProperty -Name Type -Value "DeleteMarker"
        $Versions += $DeleteMarkers

        foreach ($Version in $Versions) {
            $Version | Add-Member -MemberType NoteProperty -Name OwnerId -Value $Version.Owner.Id
            $Version | Add-Member -MemberType NoteProperty -Name OwnerDisplayName -Value $Version.Owner.DisplayName
            $Version | Add-Member -MemberType NoteProperty -Name Region -Value $Region
            $Version.PSObject.Members.Remove("Owner")
        }
        $Versions | Add-Member -MemberType NoteProperty -Name Bucket -Value $Content.ListVersionsResult.Name

        Write-Output $Versions

        if ($Content.ListVersionsResult.IsTruncated -eq "true" -and $MaxKeys -eq 0) {
            Write-Verbose "1000 Versions were returned and max keys was not limited so continuing to get all Versions"
            if ($Profile) {
                Get-S3BucketVersions -Profile $Profile -EndpointUrl $EndpointUrl -Region $Region -SkipCertificateCheck:$SkipCertificateCheck -UrlStyle $UrlStyle -Bucket $Bucket -MaxKeys $MaxKeys -Prefix $Prefix -KeyMarker $Content.ListVersionsResult.NextKeyMarker -VersionIdMarker $Content.ListVersionsResult.NextVersionIdMarker
            }
            elseif ($AccessKey) {
                Get-S3BucketVersions -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -EndpointUrl $EndpointUrl -Region $Region -SkipCertificateCheck:$SkipCertificateCheck -UrlStyle $UrlStyle -Bucket $Bucket -MaxKeys $MaxKeys -Prefix $Prefix -KeyMarker $Content.ListVersionsResult.NextKeyMarker -VersionIdMarker $Content.ListVersionsResult.NextVersionIdMarker
            }
            elseif ($AccountId) {
                Get-S3BucketVersions -AccountId $AccountId -EndpointUrl $EndpointUrl -Region $Region -SkipCertificateCheck:$SkipCertificateCheck -UrlStyle $UrlStyle -Bucket $Bucket -MaxKeys $MaxKeys -Prefix $Prefix -KeyMarker $Content.ListVersionsResult.NextKeyMarker -VersionIdMarker $Content.ListVersionsResult.NextVersionIdMarker
            }
            else {
                Get-S3BucketVersions -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -EndpointUrl $EndpointUrl -Region $Region -SkipCertificateCheck:$SkipCertificateCheck -UrlStyle $UrlStyle -Bucket $Bucket -MaxKeys $MaxKeys -Prefix $Prefix -KeyMarker $Content.ListVersionsResult.NextKeyMarker -VersionIdMarker $Content.ListVersionsResult.NextVersionIdMarker
            }
        }
    }
}

<#
    .SYNOPSIS
    Create S3 Bucket
    .DESCRIPTION
    Create S3 Bucket
#>
function Global:New-S3Bucket {
    [CmdletBinding(DefaultParameterSetName="none")]

    PARAM (
        [parameter(
            ParameterSetName="profile",
            Mandatory=$False,
            Position=0,
            HelpMessage="AWS Profile to use which contains AWS sredentials and settings")][String]$Profile,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=0,
            HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=1,
            HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
            ParameterSetName="account",
            Mandatory=$False,
            Position=0,
            HelpMessage="StorageGRID account ID to execute this command against")][String]$AccountId,
        [parameter(
            Mandatory=$False,
            Position=2,
            HelpMessage="EndpointUrl")][System.UriBuilder]$EndpointUrl,
        [parameter(
            Mandatory=$False,
            Position=3,
            HelpMessage="Skip SSL Certificate Check")][Switch]$SkipCertificateCheck,
        [parameter(
            Mandatory=$False,
            Position=4,
            HelpMessage="Path Style")][String][ValidateSet("path","virtual-hosted")]$UrlStyle="path",
        [parameter(
            Mandatory=$True,
            Position=5,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Bucket")][Alias("Name")][String]$Bucket,
        [parameter(
            Mandatory=$False,
            Position=6,
            HelpMessage="Canned ACL")][Alias("CannedAcl")][String][ValidateSet("private","public-read","public-read-write","aws-exec-read","authenticated-read","bucket-owner-read","bucket-owner-full-control")]$Acl,
        [parameter(
            Mandatory=$False,
            Position=7,
            HelpMessage="Region to create bucket in")][Alias("Location","LocationConstraint")][String]$Region

    )
 
    Process {
        $HTTPRequestMethod = "PUT"

        if ($Region) {
            $RequestPayload = "<CreateBucketConfiguration xmlns=`"http://s3.amazonaws.com/doc/2006-03-01/`"><LocationConstraint>$Region</LocationConstraint></CreateBucketConfiguration>"
        }

        $Query = @{}

        if ($Profile) {
            $Result = Invoke-AwsRequest -Profile $Profile -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -RequestPayload $RequestPayload -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccessKey) {
            $Result = Invoke-AwsRequest -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -RequestPayload $RequestPayload -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccountId) {
            $Result = Invoke-AwsRequest -AccountId $AccountId -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -RequestPayload $RequestPayload -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        else {
            $Result = Invoke-AwsRequest -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -RequestPayload $RequestPayload -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
    }
}

<#
    .SYNOPSIS
    Remove S3 Bucket
    .DESCRIPTION
    Remove S3 Bucket
#>
function Global:Remove-S3Bucket {
    [CmdletBinding(DefaultParameterSetName="none")]

    PARAM (
        [parameter(
            ParameterSetName="profile",
            Mandatory=$False,
            Position=0,
            HelpMessage="AWS Profile to use which contains AWS sredentials and settings")][String]$Profile,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=0,
            HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=1,
            HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
            ParameterSetName="account",
            Mandatory=$False,
            Position=0,
            HelpMessage="StorageGRID account ID to execute this command against")][String]$AccountId,
        [parameter(
            Mandatory=$False,
            Position=2,
            HelpMessage="EndpointUrl")][System.UriBuilder]$EndpointUrl,
        [parameter(
            Mandatory=$False,
            Position=3,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Region to be used")][String]$Region,
        [parameter(
            Mandatory=$False,
            Position=4,
            HelpMessage="Skip SSL Certificate Check")][Switch]$SkipCertificateCheck,
        [parameter(
            Mandatory=$False,
            Position=5,
            HelpMessage="Path Style")][String][ValidateSet("path","virtual-hosted")]$UrlStyle="path",
        [parameter(
            Mandatory=$True,
            Position=6,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Bucket")][Alias("Name")][String]$Bucket,
        [parameter(
            Mandatory=$False,
            Position=7,
            HelpMessage="Force deletion even if bucket is not empty.")][Switch]$Force

    )
 
    Process {
        if ($Force) {
            Write-Verbose "Force parameter specified, removing all objects in the bucket before removing the bucket"
            Get-S3Bucket -Name $Bucket -Profile $Profile | Remove-S3Object -Profile $Profile
        }

        $HTTPRequestMethod = "DELETE"

        if ($Profile) {
            $Result = Invoke-AwsRequest -Profile $Profile -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccessKey) {
            $Result = Invoke-AwsRequest -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccountId) {
            $Result = Invoke-AwsRequest -AccountId $AccountId -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }
        else {
            $Result = Invoke-AwsRequest -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }
    }
}

<#
    .SYNOPSIS
    Get S3 Bucket Versioning
    .DESCRIPTION
    Get S3 Bucket Versioning
#>
function Global:Get-S3BucketVersioning {
    [CmdletBinding(DefaultParameterSetName="none")]

    PARAM (
        [parameter(
                ParameterSetName="profile",
                Mandatory=$False,
                Position=0,
                HelpMessage="AWS Profile to use which contains AWS sredentials and settings")][String]$Profile,
        [parameter(
                ParameterSetName="keys",
                Mandatory=$False,
                Position=0,
                HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
                ParameterSetName="keys",
                Mandatory=$False,
                Position=1,
                HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
                ParameterSetName="account",
                Mandatory=$False,
                Position=0,
                HelpMessage="StorageGRID account ID to execute this command against")][String]$AccountId,
        [parameter(
                Mandatory=$False,
                Position=2,
                HelpMessage="EndpointUrl")][System.UriBuilder]$EndpointUrl,
        [parameter(
                Mandatory=$False,
                Position=3,
                ValueFromPipeline=$True,
                ValueFromPipelineByPropertyName=$True,
                HelpMessage="Region to be used")][String]$Region,
        [parameter(
                Mandatory=$False,
                Position=4,
                HelpMessage="Skip SSL Certificate Check")][Switch]$SkipCertificateCheck,
        [parameter(
                Mandatory=$False,
                Position=5,
                HelpMessage="Path Style")][String][ValidateSet("path","virtual-hosted")]$UrlStyle="path",
        [parameter(
                Mandatory=$True,
                Position=6,
                ValueFromPipeline=$True,
                ValueFromPipelineByPropertyName=$True,
                HelpMessage="Bucket")][Alias("Name")][String]$Bucket

    )

    Process {
        $Query = @{versioning=""}

        $HTTPRequestMethod = "GET"

        if ($Profile) {
            $Result = Invoke-AwsRequest -Profile $Profile -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Query $Query -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccessKey) {
            $Result = Invoke-AwsRequest -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Query $Query -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccountId) {
            $Result = Invoke-AwsRequest -AccountId $AccountId -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Query $Query -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }
        else {
            $Result = Invoke-AwsRequest -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Query $Query -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }

        # it seems AWS is sometimes not sending the Content-Type and then PowerShell does not parse the binary to string
        if (!$Result.Headers.'Content-Type') {
            $Content = [XML][System.Text.Encoding]::UTF8.GetString($Result.Content)
        }
        else {
            $Content = [XML]$Result.Content
        }

        Write-Output $Content.VersioningConfiguration.Status
    }
}

<#
    .SYNOPSIS
    Enable S3 Bucket Versioning
    .DESCRIPTION
    Enable S3 Bucket Versioning
#>
function Global:Enable-S3BucketVersioning {
    [CmdletBinding(DefaultParameterSetName="none")]

    PARAM (
        [parameter(
                ParameterSetName="profile",
                Mandatory=$False,
                Position=0,
                HelpMessage="AWS Profile to use which contains AWS sredentials and settings")][String]$Profile,
        [parameter(
                ParameterSetName="keys",
                Mandatory=$False,
                Position=0,
                HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
                ParameterSetName="keys",
                Mandatory=$False,
                Position=1,
                HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
                ParameterSetName="account",
                Mandatory=$False,
                Position=0,
                HelpMessage="StorageGRID account ID to execute this command against")][String]$AccountId,
        [parameter(
                Mandatory=$False,
                Position=2,
                HelpMessage="EndpointUrl")][System.UriBuilder]$EndpointUrl,
        [parameter(
                Mandatory=$False,
                Position=3,
                ValueFromPipeline=$True,
                ValueFromPipelineByPropertyName=$True,
                HelpMessage="Region to be used")][String]$Region,
        [parameter(
                Mandatory=$False,
                Position=4,
                HelpMessage="Skip SSL Certificate Check")][Switch]$SkipCertificateCheck,
        [parameter(
                Mandatory=$False,
                Position=5,
                HelpMessage="Path Style")][String][ValidateSet("path","virtual-hosted")]$UrlStyle="path",
        [parameter(
                Mandatory=$True,
                Position=6,
                ValueFromPipeline=$True,
                ValueFromPipelineByPropertyName=$True,
                HelpMessage="Bucket")][Alias("Name")][String]$Bucket
    )

    Process {
        $Query = @{versioning=""}

        $RequestPayload = "<VersioningConfiguration xmlns=`"http://s3.amazonaws.com/doc/2006-03-01/`"><Status>Enabled</Status></VersioningConfiguration>"

        $HTTPRequestMethod = "PUT"

        if ($Profile) {
            $Result = Invoke-AwsRequest -Profile $Profile -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Query $Query -RequestPayload $RequestPayload -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccessKey) {
            $Result = Invoke-AwsRequest -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Query $Query -RequestPayload $RequestPayload -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccountId) {
            $Result = Invoke-AwsRequest -AccountId $AccountId -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Query $Query -RequestPayload $RequestPayload -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }
        else {
            $Result = Invoke-AwsRequest -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Query $Query -RequestPayload $RequestPayload -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }

        # it seems AWS is sometimes not sending the Content-Type and then PowerShell does not parse the binary to string
        if (!$Result.Headers.'Content-Type') {
            $Content = [XML][System.Text.Encoding]::UTF8.GetString($Result.Content)
        }
        else {
            $Content = [XML]$Result.Content
        }

        Write-Output $Content.VersioningConfiguration.Status
    }
}

<#
    .SYNOPSIS
    Suspend S3 Bucket Versioning
    .DESCRIPTION
    Suspend S3 Bucket Versioning
#>
function Global:Suspend-S3BucketVersioning {
    [CmdletBinding(DefaultParameterSetName="none")]

    PARAM (
        [parameter(
                ParameterSetName="profile",
                Mandatory=$False,
                Position=0,
                HelpMessage="AWS Profile to use which contains AWS sredentials and settings")][String]$Profile,
        [parameter(
                ParameterSetName="keys",
                Mandatory=$False,
                Position=0,
                HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
                ParameterSetName="keys",
                Mandatory=$False,
                Position=1,
                HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
                ParameterSetName="account",
                Mandatory=$False,
                Position=0,
                HelpMessage="StorageGRID account ID to execute this command against")][String]$AccountId,
        [parameter(
                Mandatory=$False,
                Position=2,
                HelpMessage="EndpointUrl")][System.UriBuilder]$EndpointUrl,
        [parameter(
                Mandatory=$False,
                Position=3,
                ValueFromPipeline=$True,
                ValueFromPipelineByPropertyName=$True,
                HelpMessage="Region to be used")][String]$Region,
        [parameter(
                Mandatory=$False,
                Position=4,
                HelpMessage="Skip SSL Certificate Check")][Switch]$SkipCertificateCheck,
        [parameter(
                Mandatory=$False,
                Position=5,
                HelpMessage="Path Style")][String][ValidateSet("path","virtual-hosted")]$UrlStyle="path",
        [parameter(
                Mandatory=$True,
                Position=6,
                ValueFromPipeline=$True,
                ValueFromPipelineByPropertyName=$True,
                HelpMessage="Bucket")][Alias("Name")][String]$Bucket

    )

    Process {
        $Query = @{versioning=""}

        $RequestPayload = "<VersioningConfiguration xmlns=`"http://s3.amazonaws.com/doc/2006-03-01/`"><Status>Suspended</Status></VersioningConfiguration>"

        $HTTPRequestMethod = "PUT"

        if ($Profile) {
            $Result = Invoke-AwsRequest -Profile $Profile -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Query $Query -RequestPayload $RequestPayload -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccessKey) {
            $Result = Invoke-AwsRequest -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Query $Query -RequestPayload $RequestPayload -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccountId) {
            $Result = Invoke-AwsRequest -AccountId $AccountId -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Query $Query -RequestPayload $RequestPayload -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }
        else {
            $Result = Invoke-AwsRequest -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Query $Query -RequestPayload $RequestPayload -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }

        # it seems AWS is sometimes not sending the Content-Type and then PowerShell does not parse the binary to string
        if (!$Result.Headers.'Content-Type') {
            $Content = [XML][System.Text.Encoding]::UTF8.GetString($Result.Content)
        }
        else {
            $Content = [XML]$Result.Content
        }

        Write-Output $Content.VersioningConfiguration.Status
    }
}

Set-Alias -Name Get-S3BucketRegion -Value Get-S3BucketLocation
<#
    .SYNOPSIS
    Get S3 Bucket Location
    .DESCRIPTION
    Get S3 Bucket Location
#>
function Global:Get-S3BucketLocation {
    [CmdletBinding(DefaultParameterSetName="none")]

    PARAM (
        [parameter(
                ParameterSetName="profile",
                Mandatory=$False,
                Position=0,
                HelpMessage="AWS Profile to use which contains AWS sredentials and settings")][String]$Profile,
        [parameter(
                ParameterSetName="keys",
                Mandatory=$False,
                Position=0,
                HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
                ParameterSetName="keys",
                Mandatory=$False,
                Position=1,
                HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
                ParameterSetName="account",
                Mandatory=$False,
                Position=0,
                HelpMessage="StorageGRID account ID to execute this command against")][String]$AccountId,
        [parameter(
                Mandatory=$False,
                Position=2,
                HelpMessage="EndpointUrl")][System.UriBuilder]$EndpointUrl,
        [parameter(
                Mandatory=$False,
                Position=3,
                HelpMessage="Skip SSL Certificate Check")][Switch]$SkipCertificateCheck,
        [parameter(
                Mandatory=$False,
                Position=4,
                HelpMessage="Path Style")][String][ValidateSet("path","virtual-hosted")]$UrlStyle="path",
        [parameter(
                Mandatory=$True,
                Position=5,
                ValueFromPipeline=$True,
                ValueFromPipelineByPropertyName=$True,
                HelpMessage="Bucket")][Alias("Name")][String]$Bucket
    )

    Process {
        $Query = @{location=""}

        $HTTPRequestMethod = "GET"

        if ($Profile) {
            $Result = Invoke-AwsRequest -Profile $Profile -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Query $Query -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccessKey) {
            $Result = Invoke-AwsRequest -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Query $Query -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccountId) {
            $Result = Invoke-AwsRequest -AccountId $AccountId -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Query $Query -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }
        else {
            $Result = Invoke-AwsRequest -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Query $Query -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -ErrorAction Stop
        }

        # it seems AWS is sometimes not sending the Content-Type and then PowerShell does not parse the binary to string
        if (!$Result.Headers.'Content-Type') {
            $Content = [XML][System.Text.Encoding]::UTF8.GetString($Result.Content)
        }
        else {
            $Content = [XML]$Result.Content
        }

        Write-Output $Content.LocationConstraint.InnerText
    }
}

## Objects ##

Set-Alias -Name Get-S3Objects -Value Get-S3Bucket

Set-Alias -Name Get-S3Object -Value Get-S3Object
<#
    .SYNOPSIS
    Get S3 Object
    .DESCRIPTION
    Get S3 Object
#>
function Global:Get-S3ObjectMetadata {
    [CmdletBinding(DefaultParameterSetName="none")]

    PARAM (
        [parameter(
                ParameterSetName="profile",
                Mandatory=$False,
                Position=0,
                HelpMessage="AWS Profile to use which contains AWS sredentials and settings")][String]$Profile,
        [parameter(
                ParameterSetName="keys",
                Mandatory=$False,
                Position=0,
                HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
                ParameterSetName="keys",
                Mandatory=$False,
                Position=1,
                HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
                ParameterSetName="account",
                Mandatory=$False,
                Position=0,
                HelpMessage="StorageGRID account ID to execute this command against")][String]$AccountId,
        [parameter(
                Mandatory=$False,
                Position=2,
                HelpMessage="EndpointUrl")][System.UriBuilder]$EndpointUrl,
        [parameter(
                Mandatory=$False,
                Position=3,
                ValueFromPipeline=$True,
                ValueFromPipelineByPropertyName=$True,
                HelpMessage="Region to be used")][String]$Region,
        [parameter(
                Mandatory=$False,
                Position=4,
                HelpMessage="Skip SSL Certificate Check")][Switch]$SkipCertificateCheck,
        [parameter(
                Mandatory=$False,
                Position=5,
                HelpMessage="Path Style")][String][ValidateSet("path","virtual-hosted")]$UrlStyle="path",
        [parameter(
                Mandatory=$True,
                Position=6,
                ValueFromPipeline=$True,
                ValueFromPipelineByPropertyName=$True,
                HelpMessage="Bucket")][Alias("Name")][String]$Bucket,
        [parameter(
                Mandatory=$True,
                Position=7,
                ValueFromPipeline=$True,
                ValueFromPipelineByPropertyName=$True,
                HelpMessage="Object key")][Alias("Object")][String]$Key,
        [parameter(
                Mandatory=$False,
                Position=8,
                ValueFromPipeline=$True,
                ValueFromPipelineByPropertyName=$True,
                HelpMessage="Object version ID")][String]$VersionId
    )

    Process {
        $Uri = "/$Key"

        if ($VersionId) {
            $Query = @{versionId=$VersionId}
        }
        else {
            $Query = @{}
        }

        $HTTPRequestMethod = "HEAD"

        if ($Profile) {
            $Result = Invoke-AwsRequest -Profile $Profile -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Uri $Uri -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccessKey) {
            $Result = Invoke-AwsRequest -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Uri $Uri -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccountId) {
            $Result = Invoke-AwsRequest -AccountId $AccountId -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Uri $Uri -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        else {
            $Result = Invoke-AwsRequest -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Uri $Uri -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }

        $Headers = $Result.Headers
        $Metadata = @{}
        foreach ($Key in $Headers.Keys) {
            $MetadataKey = $Key -replace "x-amz-meta-",""
            $Metadata[$MetadataKey] = $Headers[$Key]
        }

        # TODO: Implement missing Metadata

        $PartCount = ($Headers["ETag"] -split "-")[1]

        $Output = [PSCustomObject]@{Headers=$Headers;
                                    Metadata=$Metadata;
                                    DeleteMarker=$null;
                                    AcceptRanges=$Headers.'Accept-Ranges';
                                    Expiration=$Headers["x-amz-expiration"];
                                    RestoreExpiration=$null;
                                    RestoreInProgress=$null;
                                    LastModified=$Headers.'Last-Modified';
                                    ETag=$Headers.ETag;
                                    MissingMeta=[int]$Headers["x-amz-missing-meta"];
                                    VersionId=$Headers["x-amz-version-id"];
                                    Expires=$null;
                                    WebsiteRedirectLocation=$null;
                                    ServerSideEncryptionMethod=$Headers["x-amz-server-side​-encryption"];
                                    ServerSideEncryptionCustomerMethod=$Headers["x-amz-server-side​-encryption​-customer-algorithm"];
                                    ServerSideEncryptionKeyManagementServiceKeyId=$Headers["x-amz-server-side-encryption-aws-kms-key-id"];
                                    ReplicationStatus=$Headers["x-amz-replication-status"];
                                    PartsCount=$PartCount;
                                    StorageClass=$Headers["x-amz-storage-class"];
                                    }

        Write-Output $Output
    }
}

Set-Alias -Name Get-S3Object -Value Read-S3Object
<#
    .SYNOPSIS
    Read an S3 Object
    .DESCRIPTION
    Read an S3 Object
#>
function Global:Read-S3Object {
    [CmdletBinding(DefaultParameterSetName="none")]

    PARAM (
        [parameter(
            ParameterSetName="profile",
            Mandatory=$False,
            Position=0,
            HelpMessage="AWS Profile to use which contains AWS sredentials and settings")][String]$Profile,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=0,
            HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=1,
            HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
            ParameterSetName="account",
            Mandatory=$False,
            Position=0,
            HelpMessage="StorageGRID account ID to execute this command against")][String]$AccountId,
        [parameter(
            Mandatory=$False,
            Position=2,
            HelpMessage="EndpointUrl")][System.UriBuilder]$EndpointUrl,
        [parameter(
            Mandatory=$False,
            Position=3,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Region to be used")][String]$Region,
        [parameter(
            Mandatory=$False,
            Position=4,
            HelpMessage="Skip SSL Certificate Check")][Switch]$SkipCertificateCheck,
        [parameter(
            Mandatory=$False,
            Position=5,
            HelpMessage="Path Style")][String][ValidateSet("path","virtual-hosted")]$UrlStyle="path",
        [parameter(
            Mandatory=$True,
            Position=6,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Bucket")][Alias("Name")][String]$Bucket,
        [parameter(
            Mandatory=$True,
            Position=7,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Object key")][Alias("Object")][String]$Key,
        [parameter(
            Mandatory=$False,
            Position=8,
            HelpMessage="Byte range to retrieve from object")][String]$Range,
        [parameter(
            Mandatory=$False,
            Position=9,
            HelpMessage="Path where object should be stored")][Alias("OutFile")][System.IO.DirectoryInfo]$Path
    )
 
    Process {
        $Uri = "/$Key"

        $HTTPRequestMethod = "GET"

        $Headers = @{}
        if ($Range) {            
            $Headers["Range"] = $Range
        }

        if ($Path) {
            if ($Path.Exists) {
                $Item = Get-Item $Path
                if ($Item -is [FileInfo]) {
                    $OutFile = $Item
                }
                else {
                    $OutFile = Join-Path -Path $Path -ChildPath $Key
                }
            }
            elseif ($Path.Parent.Exists) {
                $OutFile = $Path
            }
            else {
                Throw "Path $Path does not exist and parent directory $($Path.Parent) also does not exist"
            }
        }

        if ($Profile) {
            $Result = Invoke-AwsRequest -Profile $Profile -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Uri $Uri -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -Headers $Headers -OutFile $OutFile -ErrorAction Stop
        }
        elseif ($AccessKey) {
            $Result = Invoke-AwsRequest -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Uri $Uri -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -Headers $Headers -OutFile $OutFile -ErrorAction Stop
        }
        elseif ($AccountId) {
            $Result = Invoke-AwsRequest -AccountId $AccountId -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Uri $Uri -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -Headers $Headers -OutFile $OutFile -ErrorAction Stop
        }
        else {
            $Result = Invoke-AwsRequest -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Uri $Uri -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Bucket $Bucket -Headers $Headers -OutFile $OutFile -ErrorAction Stop
        }

        Write-Output $Result.Content
    }
}

<#
    .SYNOPSIS
    Write S3 Object
    .DESCRIPTION
    Write S3 Object
#>
function Global:Write-S3Object {
    [CmdletBinding(DefaultParameterSetName="none")]

    PARAM (
        [parameter(
            ParameterSetName="ProfileAndFile",
            Mandatory=$False,
            Position=0,
            HelpMessage="AWS Profile to use which contains AWS sredentials and settings")]
        [parameter(
            ParameterSetName="ProfileAndContent",
            Mandatory=$False,
            Position=0,
            HelpMessage="AWS Profile to use which contains AWS sredentials and settings")][String]$Profile,
        [parameter(
            ParameterSetName="KeyAndFile",
            Mandatory=$True,
            Position=0,
            HelpMessage="S3 Access Key")]
        [parameter(
            ParameterSetName="KeyAndContent",
            Mandatory=$True,
            Position=0,
            HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
            ParameterSetName="KeyAndFile",
            Mandatory=$True,
            Position=1,
            HelpMessage="S3 Secret Access Key")]
        [parameter(
            ParameterSetName="KeyAndContent",
            Mandatory=$True,
            Position=1,
            HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
            ParameterSetName="AccountAndFile",
            Mandatory=$True,
            Position=0,
            HelpMessage="StorageGRID account ID to execute this command against")]
        [parameter(
            ParameterSetName="AccountAndContent",
            Mandatory=$True,
            Position=0,
            HelpMessage="StorageGRID account ID to execute this command against")][String]$AccountId,
        [parameter(
            Mandatory=$False,
            Position=2,
            HelpMessage="EndpointUrl")][System.UriBuilder]$EndpointUrl,
        [parameter(
            Mandatory=$False,
            Position=3,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Region to be used")][String]$Region,
        [parameter(
            Mandatory=$False,
            Position=4,
            HelpMessage="Skip SSL Certificate Check")][Switch]$SkipCertificateCheck,
        [parameter(
            Mandatory=$False,
            Position=5,
            HelpMessage="Path Style")][String][ValidateSet("path","virtual-hosted")]$UrlStyle="path",
        [parameter(
            Mandatory=$True,
            Position=6,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Bucket")][Alias("Name")][String]$Bucket,
        [parameter(
            Mandatory=$True,
            Position=7,
            ParameterSetName="ProfileAndFile",
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Object key. If not provided, filename will be used")]
        [parameter(
            Mandatory=$True,
            Position=7,
            ParameterSetName="KeyAndFile",
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Object key. If not provided, filename will be used")]
        [parameter(
            Mandatory=$True,
            Position=7,
            ParameterSetName="AccountAndFile",
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Object key. If not provided, filename will be used")]
        [parameter(
            Mandatory=$True,
            Position=7,
            ParameterSetName="ProfileAndContent",
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Object key. If not provided, filename will be used")]
        [parameter(
            Mandatory=$True,
            Position=7,
            ParameterSetName="KeyAndContent",
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Object key. If not provided, filename will be used")]
        [parameter(
            Mandatory=$True,
            Position=7,
            ParameterSetName="AccountAndContent",
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Object key. If not provided, filename will be used")][Alias("Object")][String]$Key,
        [parameter(
            Mandatory=$True,
            Position=8,
            ParameterSetName="ProfileAndFile",
            HelpMessage="Path where object should be stored")]
        [parameter(
            Mandatory=$True,
            Position=8,
            ParameterSetName="KeyAndFile",
            HelpMessage="Path where object should be stored")]
        [parameter(
            Mandatory=$True,
            Position=8,
            ParameterSetName="AccountAndFile",
            HelpMessage="Path where object should be stored")][Alias("Path","File")][System.IO.FileInfo]$InFile,
        [parameter(
            Mandatory=$True,
            Position=8,
            ParameterSetName="ProfileAndContent",
            HelpMessage="Content of object")]
        [parameter(
            Mandatory=$True,
            Position=8,
            ParameterSetName="KeyAndContent",
            HelpMessage="Content of object")]
        [parameter(
            Mandatory=$True,
            Position=8,
            ParameterSetName="AccountAndContent",
            HelpMessage="Content of object")][Alias("InputObject")][String]$Content,
        [parameter(
            Mandatory=$False,
            Position=9,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Metadata")][Hashtable]$Metadata
    )
 
    Process {
        if ($InFile -and !$InFile.Exists) {
            Throw "File $InFile does not exist"
        }

        if ($InFile) {
            $ContentType = [System.Web.MimeMapping]::GetMimeMapping($InFile)
        }
        else {
            $ContentType = "text/plain"
        }

        if (!$Key) {
            $Key = $InFile.Name
        }

        $Headers = @{}
        if ($Metadata) {
            foreach ($Key in $Metadata.Keys) {
                $Key = $Key -replace "^x-amz-meta-",""
                $Headers["x-amz-meta-$Key"] = $Metadata[$Key]
                # TODO: check that metadata is valid HTTP Header
            }
        }
        Write-Verbose "Metadata:`n$($Headers | ConvertTo-Json)"
        
        $Uri = "/$Key"

        $HTTPRequestMethod = "PUT"

        if ($InFile) {
            if ($Profile) {
                $Result = Invoke-AwsRequest -Profile $Profile -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Headers $Headers -Region $Region -Uri $Uri -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -InFile $InFile -Bucket $Bucket -ContentType $ContentType -ErrorAction Stop
            }
            elseif ($AccessKey) {
                $Result = Invoke-AwsRequest -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Headers $Headers -Region $Region -Uri $Uri -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -InFile $InFile -Bucket $Bucket -ContentType $ContentType -ErrorAction Stop
            }
            elseif ($AccountId) {
                $Result = Invoke-AwsRequest -AccountId $AccountId -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Headers $Headers -Region $Region -Uri $Uri -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -InFile $InFile -Bucket $Bucket -ContentType $ContentType -ErrorAction Stop
            }
            else {
                $Result = Invoke-AwsRequest -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Headers $Headers -Region $Region -Uri $Uri -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -InFile $InFile -Bucket $Bucket -ContentType $ContentType -ErrorAction Stop
            }
        }
        else {
            if ($Profile) {
                $Result = Invoke-AwsRequest -Profile $Profile -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Headers $Headers -Region $Region -Uri $Uri -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -RequestPayload $Content -ContentType $ContentType -Bucket $Bucket -ErrorAction Stop
            }
            elseif ($AccessKey) {
                $Result = Invoke-AwsRequest -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl -Headers $Headers -Region $Region $EndpointUrl -Uri $Uri -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -RequestPayload $Content -ContentType $ContentType -Bucket $Bucket -ErrorAction Stop
            }
            elseif ($AccountId) {
                $Result = Invoke-AwsRequest -AccountId $AccountId -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Headers $Headers -Region $Region -Uri $Uri -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -RequestPayload $Content -ContentType $ContentType -Bucket $Bucket -ErrorAction Stop
            }
            else {
                $Result = Invoke-AwsRequest -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Headers $Headers -Region $Region -Uri $Uri -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -RequestPayload $Content -ContentType $ContentType -Bucket $Bucket -ErrorAction Stop
            }
        }

        Write-Output $Result.Content
    }
}

<#
    .SYNOPSIS
    Remove S3 Object
    .DESCRIPTION
    Remove S3 Object
#>
function Global:Remove-S3Object {
    [CmdletBinding(DefaultParameterSetName="none")]

    PARAM (
        [parameter(
            ParameterSetName="profile",
            Mandatory=$False,
            Position=0,
            HelpMessage="AWS Profile to use which contains AWS sredentials and settings")][String]$Profile,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=0,
            HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=1,
            HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
            ParameterSetName="account",
            Mandatory=$False,
            Position=0,
            HelpMessage="StorageGRID account ID to execute this command against")][String]$AccountId,
        [parameter(
            Mandatory=$False,
            Position=2,
            HelpMessage="EndpointUrl")][System.UriBuilder]$EndpointUrl,
        [parameter(
            Mandatory=$False,
            Position=3,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Region to be used")][String]$Region,
        [parameter(
            Mandatory=$False,
            Position=4,
            HelpMessage="Skip SSL Certificate Check")][Switch]$SkipCertificateCheck,
        [parameter(
            Mandatory=$False,
            Position=5,
            HelpMessage="Path Style")][String][ValidateSet("path","virtual-hosted")]$UrlStyle="path",
        [parameter(
            Mandatory=$True,
            Position=6,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Bucket")][Alias("Name")][String]$Bucket,
        [parameter(
            Mandatory=$True,
            Position=7,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Object key")][Alias("Object")][String]$Key,
        [parameter(
            Mandatory=$False,
            Position=8,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Object version ID")][String]$VersionId
    )
 
    Process {
        $Uri = "/$Key"

        if ($VersionId) {
            $Query = @{versionId=$VersionId}
        }
        else {
            $Query = @{}
        }

        $HTTPRequestMethod = "DELETE"

        if ($Profile) {
            $Result = Invoke-AwsRequest -Profile $Profile -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Uri $Uri -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccessKey) {
            $Result = Invoke-AwsRequest -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Uri $Uri -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccountId) {
            $Result = Invoke-AwsRequest -AccountId $AccountId -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Uri $Uri -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        else {
            $Result = Invoke-AwsRequest -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -Uri $Uri -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
    }
}

# StorageGRID specific #

<#
    .SYNOPSIS
    Get S3 Bucket Consistency Setting
    .DESCRIPTION
    Get S3 Bucket Consistency Setting
#>
function Global:Get-S3BucketConsistency {
    [CmdletBinding(DefaultParameterSetName="none")]

    PARAM (
        [parameter(
            ParameterSetName="profile",
            Mandatory=$False,
            Position=0,
            HelpMessage="AWS Profile to use which contains AWS sredentials and settings")][String]$Profile,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=0,
            HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=1,
            HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
            ParameterSetName="account",
            Mandatory=$False,
            Position=0,
            HelpMessage="StorageGRID account ID to execute this command against")][String]$AccountId,
        [parameter(
            Mandatory=$False,
            Position=2,
            HelpMessage="EndpointUrl")][System.UriBuilder]$EndpointUrl,
        [parameter(
            Mandatory=$False,
            Position=3,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Region to be used")][String]$Region,
        [parameter(
            Mandatory=$False,
            Position=4,
            HelpMessage="Skip SSL Certificate Check")][Switch]$SkipCertificateCheck,
        [parameter(
            Mandatory=$False,
            Position=5,
            HelpMessage="Path Style")][String][ValidateSet("path","virtual-hosted")]$UrlStyle="path",
        [parameter(
            Mandatory=$True,
            Position=6,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Bucket")][Alias("Name")][String]$Bucket
    )
 
    Process {
        $HTTPRequestMethod = "GET"

        $Query = @{"x-ntap-sg-consistency"=""}

        if ($Profile) {
            $Result = Invoke-AwsRequest -Profile $Profile -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccessKey) {
            $Result = Invoke-AwsRequest -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccountId) {
            $Result = Invoke-AwsRequest -AccountId $AccountId -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        else {
            $Result = Invoke-AwsRequest -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }

        $Content = [XML]$Result.Content

        $BucketConsistency = [PSCustomObject]@{Bucket=$Bucket;Consistency=$Content.Consistency.InnerText}

        Write-Output $BucketConsistency
    }
}

<#
    .SYNOPSIS
    Modify S3 Bucket Consistency Setting
    .DESCRIPTION
    Modify S3 Bucket Consistency Setting
#>
function Global:Update-S3BucketConsistency {
    [CmdletBinding(DefaultParameterSetName="none")]

    PARAM (
        [parameter(
            ParameterSetName="profile",
            Mandatory=$False,
            Position=0,
            HelpMessage="AWS Profile to use which contains AWS sredentials and settings")][String]$Profile,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=0,
            HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=1,
            HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
            ParameterSetName="account",
            Mandatory=$False,
            Position=0,
            HelpMessage="StorageGRID account ID to execute this command against")][String]$AccountId,
        [parameter(
            Mandatory=$False,
            Position=2,
            HelpMessage="EndpointUrl")][System.UriBuilder]$EndpointUrl,
        [parameter(
            Mandatory=$False,
            Position=3,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Region to be used")][String]$Region,
        [parameter(
            Mandatory=$False,
            Position=4,
            HelpMessage="Skip SSL Certificate Check")][Switch]$SkipCertificateCheck,
        [parameter(
            Mandatory=$False,
            Position=5,
            HelpMessage="Path Style")][String][ValidateSet("path","virtual-hosted")]$UrlStyle="path",
        [parameter(
            Mandatory=$True,
            Position=6,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Bucket")][Alias("Name")][String]$Bucket,
        [parameter(
            Mandatory=$True,
            Position=7,
            HelpMessage="Bucket")][ValidateSet("all","strong-global","strong-site","default","available","weak")][String]$Consistency
    )
 
    Process {
        $HTTPRequestMethod = "PUT"

        $Query = @{"x-ntap-sg-consistency"=$Consistency}

        if ($Profile) {
            $Result = Invoke-AwsRequest -Profile $Profile -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccessKey) {
            $Result = Invoke-AwsRequest -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccountId) {
            $Result = Invoke-AwsRequest -AccountId $AccountId -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        else {
            $Result = Invoke-AwsRequest -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
    }
}

<#
    .SYNOPSIS
    Get S3 Bucket Storage Usage
    .DESCRIPTION
    Get S3 Bucket Storage Usage
#>
function Global:Get-S3StorageUsage {
    [CmdletBinding(DefaultParameterSetName="none")]

    PARAM (
        [parameter(
            ParameterSetName="profile",
            Mandatory=$False,
            Position=0,
            HelpMessage="AWS Profile to use which contains AWS sredentials and settings")][String]$Profile,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=0,
            HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=1,
            HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
            ParameterSetName="account",
            Mandatory=$False,
            Position=0,
            HelpMessage="StorageGRID account ID to execute this command against")][String]$AccountId,
        [parameter(
            Mandatory=$False,
            Position=2,
            HelpMessage="EndpointUrl")][System.UriBuilder]$EndpointUrl,
        [parameter(
            Mandatory=$False,
            Position=3,
            HelpMessage="Skip SSL Certificate Check")][Switch]$SkipCertificateCheck
    )
 
    Process {
        $Uri = "/"

        $HTTPRequestMethod = "GET"

        $Query = @{"x-ntap-sg-usage"=""}

        if ($Profile) {
            $Result = Invoke-AwsRequest -Profile $Profile -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Uri $Uri -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -ErrorAction Stop
        }
        elseif ($AccessKey) {
            $Result = Invoke-AwsRequest -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Uri $Uri -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -ErrorAction Stop
        }
        elseif ($AccountId) {
            $Result = Invoke-AwsRequest -AccountId $AccountId -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Uri $Uri -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -ErrorAction Stop
        }
        else {
            $Result = Invoke-AwsRequest -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Uri $Uri -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -ErrorAction Stop
        }

        $UsageResult = [PSCustomObject]@{CalculationTime=(Get-Date -Date $Result.UsageResult.CalculationTime);ObjectCount=$Result.UsageResult.ObjectCount;DataBytes=$Result.UsageResult.DataBytes;buckets=$Result.UsageResult.Buckets.ChildNodes}

        Write-Output $UsageResult
    }
}

<#
    .SYNOPSIS
    Get S3 Bucket Last Access Time
    .DESCRIPTION
    Get S3 Bucket Last Access Time
#>
function Global:Get-S3BucketLastAccessTime {
    [CmdletBinding(DefaultParameterSetName="none")]

    PARAM (
        [parameter(
            ParameterSetName="profile",
            Mandatory=$False,
            Position=0,
            HelpMessage="AWS Profile to use which contains AWS sredentials and settings")][String]$Profile,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=0,
            HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=1,
            HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
            ParameterSetName="account",
            Mandatory=$False,
            Position=0,
            HelpMessage="StorageGRID account ID to execute this command against")][String]$AccountId,
        [parameter(
            Mandatory=$False,
            Position=2,
            HelpMessage="EndpointUrl")][System.UriBuilder]$EndpointUrl,
        [parameter(
            Mandatory=$False,
            Position=3,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Region to be used")][String]$Region,
        [parameter(
            Mandatory=$False,
            Position=4,
            HelpMessage="Skip SSL Certificate Check")][Switch]$SkipCertificateCheck,
        [parameter(
            Mandatory=$False,
            Position=5,
            HelpMessage="Path Style")][String][ValidateSet("path","virtual-hosted")]$UrlStyle="path",
        [parameter(
            Mandatory=$True,
            Position=6,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Bucket")][Alias("Name")][String]$Bucket
    )
 
    Process {
        $HTTPRequestMethod = "GET"

        $Query = @{"x-ntap-sg-lastaccesstime"=""}

        if ($Profile) {
            $Result = Invoke-AwsRequest -Profile $Profile -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccessKey) {
            $Result = Invoke-AwsRequest -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccountId) {
            $Result = Invoke-AwsRequest -AccountId $AccountId -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        else {
            $Result = Invoke-AwsRequest -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }

        $Content = [XML]$Result.Content

        $BucketLastAccessTime = [PSCustomObject]@{Bucket=$Bucket;LastAccessTime=$Content.LastAccessTime.InnerText}

        Write-Output $BucketLastAccessTime
    }
}

<#
    .SYNOPSIS
    Enable S3 Bucket Last Access Time
    .DESCRIPTION
    Enable S3 Bucket Last Access Time
#>
function Global:Enable-S3BucketLastAccessTime {
    [CmdletBinding(DefaultParameterSetName="none")]

    PARAM (
        [parameter(
            ParameterSetName="profile",
            Mandatory=$False,
            Position=0,
            HelpMessage="AWS Profile to use which contains AWS sredentials and settings")][String]$Profile,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=0,
            HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=1,
            HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
            ParameterSetName="account",
            Mandatory=$False,
            Position=0,
            HelpMessage="StorageGRID account ID to execute this command against")][String]$AccountId,
        [parameter(
            Mandatory=$False,
            Position=2,
            HelpMessage="EndpointUrl")][System.UriBuilder]$EndpointUrl,
        [parameter(
            Mandatory=$False,
            Position=3,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Region to be used")][String]$Region,
        [parameter(
            Mandatory=$False,
            Position=4,
            HelpMessage="Skip SSL Certificate Check")][Switch]$SkipCertificateCheck,
        [parameter(
            Mandatory=$False,
            Position=5,
            HelpMessage="Path Style")][String][ValidateSet("path","virtual-hosted")]$UrlStyle="path",
        [parameter(
            Mandatory=$True,
            Position=6,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Bucket")][Alias("Name")][String]$Bucket
    )
 
    Process {
        $HTTPRequestMethod = "PUT"

        $Query = @{"x-ntap-sg-lastaccesstime"="enabled"}

        if ($Profile) {
            $Result = Invoke-AwsRequest -Profile $Profile -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccessKey) {
            $Result = Invoke-AwsRequest -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccountId) {
            $Result = Invoke-AwsRequest -AccountId $AccountId -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        else {
            $Result = Invoke-AwsRequest -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
    }
}

<#
    .SYNOPSIS
    Disable S3 Bucket Last Access Time
    .DESCRIPTION
    Disable S3 Bucket Last Access Time
#>
function Global:Disable-S3BucketLastAccessTime {
    [CmdletBinding(DefaultParameterSetName="none")]

    PARAM (
        [parameter(
            ParameterSetName="profile",
            Mandatory=$False,
            Position=0,
            HelpMessage="AWS Profile to use which contains AWS sredentials and settings")][String]$Profile,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=0,
            HelpMessage="S3 Access Key")][String]$AccessKey,
        [parameter(
            ParameterSetName="keys",
            Mandatory=$False,
            Position=1,
            HelpMessage="S3 Secret Access Key")][String]$SecretAccessKey,
        [parameter(
            ParameterSetName="account",
            Mandatory=$False,
            Position=0,
            HelpMessage="StorageGRID account ID to execute this command against")][String]$AccountId,
        [parameter(
            Mandatory=$False,
            Position=2,
            HelpMessage="EndpointUrl")][System.UriBuilder]$EndpointUrl,
        [parameter(
            Mandatory=$False,
            Position=3,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Region to be used")][String]$Region,
        [parameter(
            Mandatory=$False,
            Position=4,
            HelpMessage="Skip SSL Certificate Check")][Switch]$SkipCertificateCheck,
        [parameter(
            Mandatory=$False,
            Position=5,
            HelpMessage="Path Style")][String][ValidateSet("path","virtual-hosted")]$UrlStyle="path",
        [parameter(
            Mandatory=$True,
            Position=6,
            ValueFromPipeline=$True,
            ValueFromPipelineByPropertyName=$True,
            HelpMessage="Bucket")][Alias("Name")][String]$Bucket
    )
 
    Process {
        $HTTPRequestMethod = "PUT"

        $Query = @{"x-ntap-sg-lastaccesstime"="disabled"}

        if ($Profile) {
            $Result = Invoke-AwsRequest -Profile $Profile -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccessKey) {
            $Result = Invoke-AwsRequest -AccessKey $AccessKey -SecretAccessKey $SecretAccessKey -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        elseif ($AccountId) {
            $Result = Invoke-AwsRequest -AccountId $AccountId -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
        else {
            $Result = Invoke-AwsRequest -HTTPRequestMethod $HTTPRequestMethod -EndpointUrl $EndpointUrl -Region $Region -UrlStyle $UrlStyle -SkipCertificateCheck:$SkipCertificateCheck -Query $Query -Bucket $Bucket -ErrorAction Stop
        }
    }
}