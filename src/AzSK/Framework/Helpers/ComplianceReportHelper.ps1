Set-StrictMode -Version Latest

class ComplianceReportHelper: ComplianceBase
{
    hidden [string] $ScanSource
	hidden [System.Version] $ScannerVersion
	hidden [string] $ScanKind 

    ComplianceReportHelper([SubscriptionContext] $subscriptionContext,[System.Version] $ScannerVersion):
    Base([SubscriptionContext] $subscriptionContext) 
	{
		$this.ScanSource = [RemoteReportHelper]::GetScanSource();
		$this.ScannerVersion = $ScannerVersion
		$this.ScanKind = [ServiceScanKind]::Partial;
	} 
	
	hidden [ComplianceStateTableEntity[]] GetSubscriptionComplianceReport()
	{
		return $this.GetSubscriptionComplianceReport("");
	}
	hidden [ComplianceStateTableEntity[]] GetSubscriptionComplianceReport($currentScanResults,$selectColumns)
	{
		$queryStringParams = "";
		$partitionKeys = @();
		if(($currentScanResults | Measure-Object).Count -gt 0)
		{
			$currentScanResults | ForEach-Object {
				$currentScanResult = $_;
				$resourceId = $currentScanResult.SubscriptionContext.Scope;
				if($currentScanResult.IsResource())
				{
					$resourceId = $currentScanResult.ResourceContext.ResourceId;
				}
				$controlsToProcess = @();
				if(($currentScanResult.ControlResults | Measure-Object).Count -gt 0)
				{	
					$controlsToProcess += $currentScanResult.ControlResults;
				}
				$controlsToProcess | ForEach-Object {
					$cScanResult = $_;												
					$currentResultHashId_p = [Helpers]::ComputeHash($resourceId.ToLower());
					$partitionKeys += $currentResultHashId_p;
				}
			}
			$partitionKeys = $partitionKeys | Select -Unique

			$template = "PartitionKey%20eq%20'{0}'";
			$tempQS = "?`$filter="
			$havePartitionKeys = $false;
			$partitionKeys | ForEach-Object {
				$pKey = $_
				$tempQS = $tempQS + ($template -f $pKey) + "%20or%20";
				$havePartitionKeys = $true;
				}
				if($havePartitionKeys)
				{
					$tempQS = $tempQS.Substring(0,$tempQS.Length - 8);
					$queryStringParams = $tempQS
				}
		}
		if(($selectColumns | Measure-Object).Count -gt 0)
		{
			$selectColumnsString = "?`$select=" + [String]::Join(",",$selectColumns)
			if([string]::IsNullOrWhiteSpace($queryStringParams))
			{
				$queryStringParams = $selectColumnsString;
			}
			else
			{
				$queryStringParams = $queryStringParams + "&" + $selectColumnsString;
			}
		}
		return $this.GetSubscriptionComplianceReport($queryStringParams);
	}
    hidden [ComplianceStateTableEntity[]] GetSubscriptionComplianceReport([string] $queryStringParams)
	{
		[ComplianceStateTableEntity[]] $complianceData = @()
		try
		{			
			$storageInstance = $this.azskStorageInstance;
			$TableName = $this.ComplianceTableName
			$AccountName = $storageInstance.StorageAccountName
			$AccessKey = $storageInstance.AccessKey 
			$Uri="https://$AccountName.table.core.windows.net/$TableName()$queryStringParams"
			$Verb = "GET"
			$ContentMD5 = ""
			$ContentType = ""
			$Date = [DateTime]::UtcNow.ToString('r')
			$CanonicalizedResource = "/$AccountName/$TableName()"
			$SigningParts=@($Verb,$ContentMD5,$ContentType,$Date,$CanonicalizedResource)
			$StringToSign = [String]::Join("`n",$SigningParts)
			$sharedKey = [Helpers]::CreateStorageAccountSharedKey($StringToSign,$AccountName,$AccessKey)

			$xmsdate = $Date
			$headers = @{"Accept"="application/json";"x-ms-date"=$xmsdate;"Authorization"="SharedKey $sharedKey";"x-ms-version"="2018-03-28"}
			$tempComplianceData  = ([WebRequestHelper]::InvokeGetWebRequest($Uri,$headers)) 
			$newEntity = [ComplianceStateTableEntity]::new();
			$props = @();
			$item = $null;
			if(($tempComplianceData | Measure-Object).Count -gt 0)
			{
				$item = $tempComplianceData[0];
			}
			if($null -ne $item)
			{
				foreach($Property in $newEntity | Get-Member -type NoteProperty, Property)
				{
					if([Helpers]::CheckMember($item, $Property.Name, $false))
					{
						$props += $Property.Name
					}
				}
				if(($props | Measure-Object).Count -gt 0)
				{
					foreach($item in $tempComplianceData)
					{
						$newEntity = [ComplianceStateTableEntity]::new()
						foreach($Property in $props){
							$newEntity.$($Property) = $item.$($Property)
						}
						if(-not [string]::IsNullOrWhiteSpace($newEntity.PartitionKey) -and -not [string]::IsNullOrWhiteSpace($newEntity.RowKey))
						{
							$complianceData+=$newEntity
						}						
					}
				}	
			}			
		}
		catch
		{
			#Write-Host $_;
			return $null;
		}
		return $complianceData;		
    }     		
		
	hidden [ComplianceStateTableEntity] ConvertScanResultToSnapshotResult($currentSVTResult, $persistedSVTResult, $svtEventContext, $partitionKey, $rowKey, $resourceId)
	{
		[ComplianceStateTableEntity] $scanResult = $null;
		if($null -ne $persistedSVTResult)
		{
			$scanResult = $persistedSVTResult;
		}
		$isLegitimateResult = ($currentSVTResult.CurrentSessionContext.IsLatestPSModule -and $currentSVTResult.CurrentSessionContext.Permissions.HasRequiredAccess -and $currentSVTResult.CurrentSessionContext.Permissions.HasAttestationReadPermissions)
		if($isLegitimateResult)
		{
			$controlItem = $svtEventContext.ControlItem;
			if($null -eq $scanResult)
			{
				$scanResult = [ComplianceStateTableEntity]::new();
				$scanResult.PartitionKey = $partitionKey;
				$scanResult.RowKey = $rowKey;		
			}						
			$scanResult.ResourceId = $resourceId;
			$scanResult.FeatureName = $svtEventContext.FeatureName; 
			if($svtEventContext.IsResource())
			{
				$scanResult.ResourceName = $svtEventContext.ResourceContext.ResourceName;
				$scanResult.ResourceGroupName = $svtEventContext.ResourceContext.ResourceGroupName;
			}
			if($scanResult.VerificationResult -ne $currentSVTResult.VerificationResult.ToString())
			{
				$scanResult.LastResultTransitionOn = [System.DateTime]::UtcNow.ToString("s");
				$scanResult.PreviousVerificationResult = $scanResult.VerificationResult;
			}

			if($scanResult.FirstScannedOn -eq [Constants]::AzSKDefaultDateTime)
			{
				$scanResult.FirstScannedOn = [System.DateTime]::UtcNow.ToString("s");
			}

			if($scanResult.FirstFailedOn -eq [Constants]::AzSKDefaultDateTime -and $currentSVTResult.ActualVerificationResult -ne [VerificationResult]::Passed)
			{
				$scanResult.FirstFailedOn = [System.DateTime]::UtcNow.ToString("s");
			}

			$scanResult.ScannedBy = [Helpers]::GetCurrentRMContext().Account
			$scanResult.ScanSource = $this.ScanSource
			$scanResult.ScannerVersion = $this.ScannerVersion
			#TODO check in the case sub control					
			$scanResult.ChildResourceName = $currentSVTResult.ChildResourceName 			
			$scanResult.ControlId = $controlItem.ControlId 			
			$scanResult.ControlIntId = $controlItem.Id 
			$scanResult.ControlSeverity = $controlItem.ControlSeverity.ToString()
			$scanResult.ActualVerificationResult = $currentSVTResult.ActualVerificationResult.ToString(); 
			$scanResult.AttestationStatus = $currentSVTResult.AttestationStatus.ToString();
			if($scanResult.AttestationStatus.ToString() -ne [AttestationStatus]::None -and $null -ne $currentSVTResult.StateManagement -and $null -ne $currentSVTResult.StateManagement.AttestedStateData)
			{
				if($scanResult.FirstAttestedOn -eq [Constants]::AzSKDefaultDateTime)
				{
					$scanResult.FirstAttestedOn = $currentSVTResult.StateManagement.AttestedStateData.AttestedDate.ToString("s");
				}

				if($currentSVTResult.StateManagement.AttestedStateData.AttestedDate -gt $scanResult.AttestedDate)
				{
					$scanResult.AttestationCounter = $scanResult.AttestationCounter + 1 
				}
				$scanResult.AttestedBy =  $currentSVTResult.StateManagement.AttestedStateData.AttestedBy
				$scanResult.AttestedDate = $currentSVTResult.StateManagement.AttestedStateData.AttestedDate.ToString("s");
				$scanResult.Justification = $currentSVTResult.StateManagement.AttestedStateData.Justification
			}
			else
			{
				$scanResult.AttestedBy = ""
				$scanResult.AttestedDate = [Constants]::AzSKDefaultDateTime.ToString("s") ;
				$scanResult.Justification = ""				
			}
			if($currentSVTResult.VerificationResult -ne [VerificationResult]::Manual)
			{
				$scanResult.VerificationResult = $currentSVTResult.VerificationResult
			}
			else {
				$scanResult.VerificationResult = $currentSVTResult.ActualVerificationResult.ToString();
			}
			$scanResult.ScannerModuleName = [Constants]::AzSKModuleName
			$scanResult.IsLatestPSModule = $currentSVTResult.CurrentSessionContext.IsLatestPSModule
			$scanResult.HasRequiredPermissions = $currentSVTResult.CurrentSessionContext.Permissions.HasRequiredAccess
			$scanResult.HasAttestationWritePermissions = $currentSVTResult.CurrentSessionContext.Permissions.HasAttestationWritePermissions
			$scanResult.HasAttestationReadPermissions = $currentSVTResult.CurrentSessionContext.Permissions.HasAttestationReadPermissions
			$scanResult.UserComments = $currentSVTResult.UserComments
			$scanResult.IsBaselineControl = $controlItem.IsBaselineControl
			
			if($controlItem.Tags.Contains("OwnerAccess") -or $controlItem.Tags.Contains("GraphRead"))
			{
				$scanResult.HasOwnerAccessTag = $true
			}
			$scanResult.LastScannedOn = [DateTime]::UtcNow.ToString('s')
		}
						
		return $scanResult
	}

	#new functions	
	
	hidden [ComplianceStateTableEntity[]] MergeSVTScanResult($currentScanResults)
	{
		if($currentScanResults.Count -lt 1) { return $null}
		[ComplianceStateTableEntity[]] $finalScanData = @()
		#TODO
		$SVTEventContextFirst = $currentScanResults[0]

		#TODO get specific data
		$complianceReport = $this.GetSubscriptionComplianceReport($currentScanResults, $null);
		# $inActiveRecords = @();
		# $complianceReport | ForEach-Object { 
		# 	$record = $_;
		# 	if($_.RowKey -eq "EmptyResource")
		# 	{
		# 		$record.IsActive = $false;
		# 		$inActiveRecords += $record;
		# 	}
		# }
		$foundPersistedData = ($complianceReport | Measure-Object).Count -gt 0
		$currentScanResults | ForEach-Object {
			$currentScanResult = $_
			$resourceId = $currentScanResult.SubscriptionContext.Scope;
			if($currentScanResult.IsResource())
			{
				$resourceId = $currentScanResult.ResourceContext.ResourceId;
			}
			if($currentScanResult.FeatureName -ne "AzSKCfg")
			{
				$controlsToProcess = @();

				if(($currentScanResult.ControlResults | Measure-Object).Count -gt 0)
				{	
					$controlsToProcess += $currentScanResult.ControlResults;
				}
				
				$controlsToProcess | ForEach-Object {
					$cScanResult = $_;
					$partsToHash = $currentScanResult.ControlItem.Id;
					if(-not [string]::IsNullOrWhiteSpace($cScanResult.ChildResourceName))
					{
						$partsToHash = $partsToHash + ":" + $cScanResult.ChildResourceName;
					}
					$currentResultHashId_r = [Helpers]::ComputeHash($partsToHash.ToLower());
					$currentResultHashId_p = [Helpers]::ComputeHash($resourceId.ToLower());
					$persistedScanResult = $null;
					if($foundPersistedData)
					{
						$persistedScanResult = $complianceReport | Where-Object { $_.PartitionKey -eq $currentResultHashId_p -and $_.RowKey -eq $currentResultHashId_r }
						# if(($persistedScanResult | Measure-Object).Count -le 0)
						# {
						# 	$foundPersistedData = $false;
						# }				
					}
					$mergedScanResult = $this.ConvertScanResultToSnapshotResult($cScanResult, $persistedScanResult, $currentScanResult, $currentResultHashId_p, $currentResultHashId_r, $resourceId)
					if($null -ne $mergedScanResult)
					{
						$finalScanData += $mergedScanResult;
					}
				}
			}
		}
		# $finalScanData += $inActiveRecords;

		return $finalScanData
	}
	hidden [void] SetLocalSubscriptionScanReport([ComplianceStateTableEntity[]] $scanResultForStorage)
	{		
		$storageInstance = $this.azskStorageInstance;

		$groupedScanResultForStorage = $scanResultForStorage | Group-Object { $_.PartitionKey}
		$groupedScanResultForStorage | ForEach-Object {
			$group = $_;
			$results = $_.Group;
			#MERGE batch req sample
			[WebRequestHelper]::InvokeTableStorageBatchWebRequest($storageInstance.ResourceGroupName,$storageInstance.StorageAccountName,$this.ComplianceTableName,$results,$true, $storageInstance.AccessKey)
			#POST batch req sample
			#[WebRequestHelper]::InvokeTableStorageBatchWebRequest($storageInstance.ResourceGroupName,$storageInstance.StorageAccountName,$this.ComplianceTableName,$results,$false)
		}		
    }
	hidden [void] StoreComplianceDataInUserSubscription([SVTEventContext[]] $currentScanResult)
	{
		$filteredResources = $null		
		$finalScanReport = $this.MergeSVTScanResult($currentScanResult)
		$this.SetLocalSubscriptionScanReport($finalScanReport)
	}
}