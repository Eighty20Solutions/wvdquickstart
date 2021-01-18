# This version of the inputValidation script is only used when starting with a new or empty Azure subscription.

<#

.DESCRIPTION
This script is ran by the inputValidationRunbook and validates the following:
 * Azure admin credentials and owner & company administrator role
 * If the required resource providers are registered (and if not, the script registers them)
Then, this script will create the AAD DC Administrators user group and add a temporary admin user to it.
Additionally, this script assigns the subscription Contributor role to the WVDServicePrincipal MSI

#>

#Initializing variables from automation account
$SubscriptionId = Get-AutomationVariable -Name 'subscriptionid'
$ResourceGroupName = Get-AutomationVariable -Name 'ResourceGroupName'
$fileURI = Get-AutomationVariable -Name 'fileURI'
$resourceTags = Get-AutomationVariable -Name 'tags'


Write-Output "Read Variables $SubscriptionId $ResourceGroupName $fileURI $resourceTags"

# Handle the tags from Json for various PowerShell commandlets to be able to handle
#Hashtable tags for Azure cmdlets which would not work with the JObject that the tags are parsed with by default
[hashtable]$hashTags = $null
$hashTags = @{}
[int]$loopindex = 0
#Enumerate through Json JObject and create String and Hashtable versions
foreach ($tags in $resourceTags.GetEnumerator()) {
    #Write-Output $loopindex
	#Write-Output @($resourceTags)[$loopindex].ToString()
	#[string]$thistag = @($resourceTags)[$loopindex].ToString() -replace ": ", "="
	#$tagsValue = "{0}{1}{2}" -f $tagsValue, $thistag,"; "
    #Write-Output $thistag
	$hashTags.add((@($resourceTags)[$loopindex].ToString().Split(':'))[0].Trim(),(@($resourceTags)[$loopindex].ToString().Split(':'))[1].Trim())
    #increment the loop for the next JObject item
    $loopindex++    
}

#$tagsValue = "{0}{1}" -f $tagsValue, "}"
#$tagsValue = $tagsValue -replace "; }", "}"
#Write-Output $tagsValue
#Write-Output $hashTags
#"Microsoft.PowerShell.Core", "Microsoft.PowerShell.Host" | ForEach-Object {
#	Write-Output $loopindex
#	$_.Split(".")
#	$loopindex++
#}

# Download files required for this script from github ARMRunbookScripts/static folder
$FileNames = "msft-wvd-saas-api.zip,msft-wvd-saas-web.zip,AzureModules.zip"
$SplitFilenames = $FileNames.split(",")
foreach($Filename in $SplitFilenames){
	Write-Output "$fileURI/ARMRunbookScripts/static/$Filename"
	Invoke-WebRequest -Uri "$fileURI/ARMRunbookScripts/static/$Filename" -OutFile "C:\$Filename"
}

#New-Item -Path "C:\msft-wvd-saas-offering" -ItemType directory -Force -ErrorAction SilentlyContinue
Expand-Archive "C:\AzureModules.zip" -DestinationPath 'C:\Modules\Global' -ErrorAction SilentlyContinue

# Install required Az modules and AzureAD
Import-Module Az.Accounts -Global
Import-Module Az.Resources -Global
Import-Module Az.Websites -Global
Import-Module Az.Automation -Global
Import-Module Az.Managedserviceidentity -Global
Import-Module Az.Keyvault -Global
Import-Module Az.Network -Global
Import-Module AzureAD -Global

Set-ExecutionPolicy -ExecutionPolicy Undefined -Scope Process -Force -Confirm:$false
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine -Force -Confirm:$false
Get-ExecutionPolicy -List

#The name of the Automation Credential Asset this runbook will use to authenticate to Azure.
$AzCredentialsAsset = 'AzureCredentials'

#Authenticate Azure
#Get the credential with the above name from the Automation Asset store
$AzCredentials = Get-AutomationPSCredential -Name $AzCredentialsAsset
$AzCredentials.password.MakeReadOnly()
Connect-AzAccount -Environment 'AzureCloud' -Credential $AzCredentials
Select-AzSubscription -SubscriptionId $SubscriptionId

$context = Get-AzContext
if ($null -eq $context)
{
	Write-Error "Please authenticate to Azure & Azure AD using Login-AzAccount and Connect-AzureAD cmdlets and then run this script"
	throw
}
$AADUsername = $context.Account.Id

#region connect to Azure and check if Owner
Try {
	Write-Output "Try to connect AzureAD."
	Connect-AzureAD -Credential $AzCredentials
	
	Write-Output "Connected to AzureAD."
	
	# get user object 
	$userInAzureAD = Get-AzureADUser -Filter "UserPrincipalName eq `'$AADUsername`'"

	$isOwner = Get-AzRoleAssignment -ObjectID $userInAzureAD.ObjectId | Where-Object { $_.RoleDefinitionName -eq "Owner"}

	if ($isOwner.RoleDefinitionName -eq "Owner") {
		Write-Output $($AADUsername + " has Owner role assigned")        
	} 
	else {
		Write-Output "Missing Owner role."   
		Throw
	}
}
Catch {    
	Write-Output  $($AADUsername + " does not have Owner role assigned")
}
#endregion

#region connect to Azure and check if admin on Azure AD 
Try {
	# this depends on the previous segment completeing 
	$role = Get-AzureADDirectoryRole | Where-Object {$_.displayName -eq 'Global Administrator'}
	$isMember = Get-AzureADDirectoryRoleMember -ObjectId $role.ObjectId | Get-AzureADUser | Where-Object {$_.UserPrincipalName -eq $AADUsername}
	
	if ($isMember.UserType -eq "Member") {
		Write-Output $($AADUsername + " has " + $role.DisplayName + " role assigned")        
	} 
	else {
		Write-Output "Missing Owner role."   
		Throw
	}
}
Catch {    
	Write-Output  $($AADUsername + " does not have " + $role.DisplayName + " role assigned")
}
#endregion

#region check Microsoft.DesktopVirtualization resource provider has been registered 
$wvdResourceProviderName = "Microsoft.DesktopVirtualization","Microsoft.AAD","microsoft.visualstudio"
foreach($resourceProvider in $wvdResourceProviderName) {
	try {
		Get-AzResourceProvider -ListAvailable | Where-Object { $_.ProviderNamespace -eq $wvdResourceProviderName  }
		Write-Output  $($resourceProvider + " is registered!" )
	}
	Catch {
		Write-Output  $("Resource provider " + $resourceProvider + " is not registered")
		try {
			Write-Output  $("Registering " + $resourceProvider )
			Register-AzResourceProvider -ProviderNamespace $resourceProvider
			Write-Output  $("Registration of " + $resourceProvider + " completed!" )
		} 
		catch {
			Write-Output  $("Registering " + $resourceProvider + " has failed!" )
		}
	}
}
#endregion

# Set up an Azure Policy at the resource group level for the resources to inherit tags from the parent resource group

$resourcegroup = Get-AzResourceGroup -Name $ResourceGroupName

#Write-Output  $resourcegroup.ResourceId

$definition = New-AzPolicyDefinition -Name "inherit-resourcegroup-tag-if-missing" -DisplayName "Inherit a tag from the resource group if missing" -description "Adds the specified tag with its value from the parent resource group when any resource missing this tag is created or updated. Existing resources can be remediated by triggering a remediation task. If the tag exists with a different value it will not be changed." -Policy 'https://raw.githubusercontent.com/Azure/azure-policy/master/samples/Tags/inherit-resourcegroup-tag-if-missing/azurepolicy.rules.json' -Parameter 'https://raw.githubusercontent.com/Azure/azure-policy/master/samples/Tags/inherit-resourcegroup-tag-if-missing/azurepolicy.parameters.json' -Mode Indexed
New-AzPolicyAssignment -Name "Inherit the resource group tags for all WVD resources" -Scope $resourcegroup.ResourceId -tagName $hashTags -PolicyDefinition $definition -AssignIdentity -Location australiaeast

# Tag the resource group with the user specified tags
Set-AzResourceGroup -Name $ResourceGroupName -Tag $hashTags
