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
$domainName = Get-AutomationVariable -Name 'domainName'
$resourceTags = Get-AutomationVariable -Name 'tags'

# Download files required for this script from github ARMRunbookScripts/static folder
$FileNames = "msft-wvd-saas-api.zip,msft-wvd-saas-web.zip,AzureModules.zip"
$SplitFilenames = $FileNames.split(",")
foreach($Filename in $SplitFilenames){
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

$PasswordProfile = New-Object -TypeName Microsoft.Open.AzureAD.Model.PasswordProfile

$username = "tempUser@" + $domainName

$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AzCredentials.password)
$UnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
$PasswordProfile.Password = $UnsecurePassword
$PasswordProfile.ForceChangePasswordNextLogin = $False

New-AzureADUser -DisplayName $username -PasswordProfile $PasswordProfile -UserPrincipalName $username -AccountEnabled $true -MailNickName "tempUser"

$domainUser = Get-AzureADUser -Filter "UserPrincipalName eq '$($username)'" | Select-Object ObjectId
# Fetch user to assign to role
$roleMember = Get-AzureADUser -ObjectId $domainUser.ObjectId

# Fetch User Account Administrator role instance
$role = Get-AzureADDirectoryRole | Where-Object {$_.displayName -eq 'Global Administrator'}
# If role instance does not exist, instantiate it based on the role template
if ($null -eq $role) {
    # Instantiate an instance of the role template
    $roleTemplate = Get-AzureADDirectoryRoleTemplate | Where-Object {$_.displayName -eq 'Global Administrator'}
    Enable-AzureADDirectoryRole -RoleTemplateId $roleTemplate.ObjectId
    # Fetch User Account Administrator role instance again
    $role = Get-AzureADDirectoryRole | Where-Object {$_.displayName -eq 'Global Administrator'}
}
# Add user to role
Add-AzureADDirectoryRoleMember -ObjectId $role.ObjectId -RefObjectId $roleMember.ObjectId
# Fetch role membership for role to confirm
Get-AzureADDirectoryRoleMember -ObjectId $role.ObjectId | Get-AzureADUser

# Add user to Security Group to exclude them from MFA requirement (to automate deployment scripts)
# TODO - parameterise Security Group Name
$WVDAdminGroupObjectId = Get-AzureADGroup -Filter "DisplayName eq 'WVD Automation Admins'" | Select-Object ObjectId
Add-AzureADGroupMember -ObjectId $WVDAdminGroupObjectId.ObjectId -RefObjectId $roleMember.ObjectId

New-AzADServicePrincipal -ApplicationId "2565bd9d-da50-47d4-8b85-4c97f669dc36"

# Create domain controller admin group
New-AzureADGroup -DisplayName "AAD DC Administrators" `
                 -Description "Delegated group to administer Azure AD Domain Services" `
                 -SecurityEnabled $true -MailEnabled $false `
                 -MailNickName "AADDCAdministrators"

# Add user to "AAD DC Administrators" group

# First, retrieve the object ID of the newly created 'AAD DC Administrators' group.
$GroupObjectId = Get-AzureADGroup -Filter "DisplayName eq 'AAD DC Administrators'" | Select-Object ObjectId

# Add the user to the 'AAD DC Administrators' group.
Add-AzureADGroupMember -ObjectId $GroupObjectId.ObjectId -RefObjectId $domainUser.ObjectId

# Grant managed identity contributor role on subscription level
$identity = Get-AzUserAssignedIdentity -ResourceGroupName $ResourceGroupName -Name "WVDServicePrincipal"
New-AzRoleAssignment -RoleDefinitionName "Contributor" -ObjectId $identity.PrincipalId -Scope "/subscriptions/$subscriptionId"
Start-Sleep -Seconds 5

# Handle the tags from Json for various PowerShell commandlets to be able to handle
#Hashtable tags for Azure cmdlets which would not work with the JObject that the tags are parsed with by default
[hashtable]$hashTags = $null
$hashTags = @{}
[int]$loopindex = 0
# Set up an Azure Policy at the resource group level for the resources to inherit tags from the parent resource group

$resourcegroup = Get-AzResourceGroup -Name $ResourceGroupName$definition = New-AzPolicyDefinition -Name "inherit-resourcegroup-tag-if-missing" -DisplayName "Inherit a tag from the resource group if missing" -description "Adds the specified tag with its value from the parent resource group when any resource missing this tag is created or updated. Existing resources can be remediated by triggering a remediation task. If the tag exists with a different value it will not be changed." -Policy 'https://raw.githubusercontent.com/Azure/azure-policy/master/samples/Tags/inherit-resourcegroup-tag-if-missing/azurepolicy.rules.json' -Parameter 'https://raw.githubusercontent.com/Azure/azure-policy/master/samples/Tags/inherit-resourcegroup-tag-if-missing/azurepolicy.parameters.json' -Mode Indexed

#Enumerate through Json JObject and create String and Hashtable versions / assign policy
foreach ($tags in $resourceTags.GetEnumerator()) {
	#Retrieve tag values from Json, replace " and split by :
	$individualtagName = (@($resourceTags)[$loopindex].ToString().Split(':'))[0].Trim()  -replace "\""", ""
	$individualtagValue = (@($resourceTags)[$loopindex].ToString().Split(':'))[1].Trim()  -replace "\""", ""
	$hashTags.add($individualtagName, $individualtagValue)
	
	#Assign Azure Policy for this tag to be inherited from this resource group to all resources, this needs to be done manually from all tags
	New-AzPolicyAssignment -Name "Inherit tags $individualtagName from $ResourceGroupName to all resources" -Scope $resourcegroup.ResourceId -tagName $individualtagName -PolicyDefinition $definition -AssignIdentity -Location australiaeast

  	$loopindex++    
}


# Tag the resource group with the user specified tags
Set-AzResourceGroup -Name $ResourceGroupName -Tag $hashTags