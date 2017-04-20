Function Test-DbaLastBackup
{
<#
.SYNOPSIS
Quickly and easily tests the last set of full backups for a server

.DESCRIPTION
Restores all or some of the latest backups and performs a DBCC CHECKTABLE

1. Gathers information about the last full backups
2. Restores the backps to the Destination with a new name. If no Destination is specified, the originating SqlServer wil be used.
3. The database is restored as "dbatools-testrestore-$databaseName" by default, but you can change dbatools-testrestore to whatever you would like using -Prefix
4. The internal file names are also renamed to prevent conflicts with original database
5. A DBCC CHECKTABLE is then performed
6. And the test database is finally dropped

.PARAMETER SqlInstance
The SQL Server to connect to. Unlike many of the other commands, you cannot specify more than one server.

.PARAMETER Destination
The destination server to use to test the restore. By default, the Destination will be set to the source server
	
If a different Destination server is specified, you must ensure that the database backups are on a shared location
	
.PARAMETER SqlCredential
Allows you to login to servers using alternative credentials

$scred = Get-Credential, then pass $scred object to the -SqlCredential parameter

Windows Authentication will be used if SqlCredential is not specified

.PARAMETER DestinationCredential
Allows you to login to servers using alternative credentials

$scred = Get-Credential, then pass $scred object to the -SqlCredential parameter

Windows Authentication will be used if SqlCredential is not specified

.PARAMETER Databases
The database backups to test. If -Databases is not provided, all database backups will be tested

.PARAMETER Exclude
Exclude specific Database backups to test

.PARAMETER DataDirectory
The command uses the SQL Server's default data directory for all restores. Use this parameter to specify a different directory for mdfs, ndfs and so on. 

.PARAMETER LogDirectory
The command uses the SQL Server's default log directory for all restores. Use this parameter to specify a different directory for ldfs. 

.PARAMETER VerifyOnly
Do not perform the actual restore. Just perform a VERIFYONLY

.PARAMETER NoCheck
Skip DBCC CHECKTABLE

.PARAMETER NoDrop
Do not drop newly created test database

.PARAMETER CopyDestination
Will copy the backup file to the destination default backup location.

.PARAMETER MaxMB
Do not restore databases larger than MaxMB

.PARAMETER IgnoreCopyOnly
If set, copy only backups will not be counted as a last backup

.PARAMETER Prefix
The database is restored as "dbatools-testrestore-$databaseName" by default. You can change dbatools-testrestore to whatever you would like using this parameter.
	
.PARAMETER WhatIf
Shows what would happen if the command were to run
	
.PARAMETER Confirm
Prompts for confirmation of every step. For example:

Are you sure you want to perform this action?
Performing the operation "Restoring model as dbatools-testrestore-model" on target "SQL2016\VNEXT".
[Y] Yes  [A] Yes to All  [N] No  [L] No to All  [S] Suspend  [?] Help (default is "Y"):
	
.PARAMETER Silent 
Use this switch to disable any kind of verbose messages

.NOTES
Tags: DisasterRecovery, Backup, Restore
dbatools PowerShell module (https://dbatools.io, clemaire@gmail.com)
Copyright (C) 2016 Chrissy LeMaire

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program.  If not, see <http://www.gnu.org/licenses/>.

.LINK
https://dbatools.io/Test-DbaLastBackup

.EXAMPLE 
Test-DbaLastBackup -SqlServer sql2016

Determines the last full backup for ALL databases, attempts to restore all databases (with a different name and file structure), then performs a DBCC CHECKTABLE

Once the test is complete, the test restore will be dropped

.EXAMPLE 
Test-DbaLastBackup -SqlServer sql2016 -Databases master

Determines the last full backup for master, attempts to restore it, then performs a DBCC CHECKTABLE

.EXAMPLE 
Test-DbaLastBackup -SqlServer sql2016 -Databases model, master -VerifyOnly

.EXAMPLE 
Test-DbaLastBackup -SqlServer sql2016 -NoCheck -NoDrop

Skips the DBCC CHECKTABLE check. This can help speed up the tests but makes it less tested. NoDrop means that the test restores will remain on the server.

.EXAMPLE 
Test-DbaLastBackup -SqlServer sql2016 -DataDirectory E:\bigdrive -LogDirectory L:\bigdrive -MaxMB 10240

Restores data and log files to alternative locations and only restores databases that are smaller than 10 GB

.EXAMPLE 
Test-DbaLastBackup -SqlServer sql2014 -Destination sql2016 -CopyDestination

Copies the backup files for sql2014 databases to sql2016 default backup locations and then attempts restore from there.

#>
	[CmdletBinding(SupportsShouldProcess = $true)]
	Param (
		[parameter(Mandatory = $true, ValueFromPipeline = $true)]
		[Alias("ServerInstance", "SqlServer", "Source")]
		[object[]]$SqlInstance,
		[object]$SqlCredential,
		[object]$Destination = $SqlInstance,
		[object]$DestinationCredential,
		[string]$DataDirectory,
		[string]$LogDirectory,
		[string]$Prefix = "dbatools-testrestore-",
		[switch]$VerifyOnly,
		[switch]$NoCheck,
		[switch]$NoDrop,
		[switch]$CopyDestination,
		[int]$MaxMB,
		[switch]$IgnoreCopyOnly,
		[switch]$Silent
	)
	
	DynamicParam { if ($SqlInstance) { return Get-ParamSqlDatabases -SqlServer $SqlInstance[0] -SqlCredential $SqlCredential } }
	
	PROCESS
	{
		foreach ($instance in $sqlinstance)
		{
			$databases = $psboundparameters.Databases
			$exclude = $psboundparameters.Exclude
			
			if ($instance -eq $destination)
			{
				$DestinationCredential = $SqlCredential
			}
			
			try
			{
				Write-Message -Level Verbose -Message "Connecting to $instance"
				$sourceserver = Connect-SqlServer -SqlServer $instance -SqlCredential $sqlCredential
			}
			catch
			{
				Stop-Function -Message "Failed to connect to: $instance" -Target $instance -Continue
			}
			
			try
			{
				Write-Message -Level Verbose -Message "Connecting to $instance"
				$destserver = Connect-SqlServer -SqlServer $destination -SqlCredential $DestinationCredential
			}
			catch
			{
				Stop-Function -Message "Failed to connect to: $destination" -Target $destination -Continue
			}
			
			if ($destserver.VersionMajor -lt $sourceserver.VersionMajor)
			{
				Stop-Function -Message "$Destination is a lower version than $instance. Backups would be incompatible." -Continue
			}
			
			if ($destserver.VersionMajor -eq $sourceserver.VersionMajor -and $destserver.VersionMinor -lt $sourceserver.VersionMinor)
			{
				Stop-Function -Message "$Destination is a lower version than $instance. Backups would be incompatible." -Continue
			}
			
			if ($instance -ne $destination)
			{
				$sourcerealname = $sourceserver.DomainInstanceName
				$destrealname = $sourceserver.DomainInstanceName
				
				if ($BackupFolder)
				{
					if ($BackupFolder.StartsWith("\\") -eq $false -and $sourcerealname -ne $destrealname)
					{
						Stop-Function -Message "Backup folder must be a network share if the source and destination servers are not the same." -Continue
					}
				}
			}
			
			$source = $sourceserver.DomainInstanceName
			$destination = $destserver.DomainInstanceName
						
			if ($datadirectory)
			{
				if (!(Test-SqlPath -SqlServer $destserver -Path $datadirectory))
				{
					$serviceaccount = $destserver.ServiceAccount
					Stop-Function -Message "Can't access $datadirectory Please check if $serviceaccount has permissions" -Continue
				}
			}
			else
			{
				$datadirectory = Get-SqlDefaultPaths -SqlServer $destserver -FileType mdf
			}
			
			if ($logdirectory)
			{
				if (!(Test-SqlPath -SqlServer $destserver -Path $logdirectory))
				{
					$serviceaccount = $destserver.ServiceAccount
					Stop-Function -Message "$Destination can't access its local directory $logdirectory. Please check if $serviceaccount has permissions" -Continue
				}
			}
			else
			{
				$logdirectory = Get-SqlDefaultPaths -SqlServer $destserver -FileType ldf
			}
			
			if ($databases.count -eq 0)
			{
				$databases = $sourceserver.databases.Name
			}
			
			if ($databases -or $exclude)
			{
				$dblist = $databases
				
				if ($exclude)
				{
					$dblist = $dblist | Where-Object $_ -notin $exclude
				}
				
				Write-Message -Level Verbose -Message "Getting recent backup history for $instance"
				
				foreach ($dbname in $dblist)
				{
					if ($dbname -eq 'tempdb')
					{
						Stop-Function -Message "Skipping tempdb" -Continue
					}
					
					Write-Message -Level Verbose -Message "Processing $dbname"
					
					$db = $sourceserver.databases[$dbname]
					
					# The db check is needed when the number of databases exceeds 255, then it's no longer autopopulated
					if (!$db)
					{
						Stop-Function -Message "$dbname does not exist on $source." -Continue
					}
					
					$lastbackup = Get-DbaBackupHistory -SqlServer $sourceserver -Databases $dbname -LastFull -IgnoreCopyOnly:$ignorecopyonly

					if($lastbackup[0].Path.StartsWith('\\') -eq $false -and $CopyDestination -eq $true) 
					{
						Write-Message -Level Verbose -Message "Copying backup to destination server"
						if ((Test-SqlPath -SqlServer $destserver -path $destserver.BackupDirectory) -eq $true) 
						{
							if((Test-SqlPath -SqlServer $destserver -path ("{0}\{1}" -f $destserver.BackupDirectory,$Prefix)) -eq $false)
							{
								New-Item -Path ("{0}\{1}" -f $destserver.BackupDirectory,$Prefix) -ItemType Directory | Out-Null
							}
							Copy-Item -Path ("\\{0}\{1}" -f $lastbackup.Computername, $lastbackup.Path.replace(':','$')) -Destination ("{0}\{1}\{2}" -f $destserver.BackupDirectory,$Prefix,$lastbackup.path.split('\')[-1])
							$lastbackup.path = ("{0}\{1}\{2}" -f $destserver.BackupDirectory,$Prefix,$lastbackup.path.split('\')[-1])
							$lastbackup.fullname = ("{0}\{1}\{2}" -f $destserver.BackupDirectory,$Prefix,$lastbackup.path.split('\')[-1])
						}
						else
						{
							Write-Message -Level Verbose -Message "Destination server default backup location doesn't exist"
						}

					}
					elseif ($CopyDestination -eq $true) {
						Write-Message -Level Verbose -Message "Ignoring CopyDestination flag, using UNC path."
					}

					if ($null -eq $lastbackup)
					{
						Write-Message -Level Verbose -Message "No data returned from lastbackup"
						
						$lastbackup = @{ Path = "Not found" }
						$fileexists = $false
						$restoreresult = "Skipped"
						$dbccresult = "Skipped"
					}
					elseif ($source -ne $destination -and $lastbackup[0].Path.StartsWith('\\') -eq $false)
					{
						Write-Message -Level Verbose -Message "Path not UNC and source does not match destination. Use -CopyDestination to move the backup file."
						$fileexists = "Skipped"
						$restoreresult = "Restore not located on shared location"
						$dbccresult = "Skipped"
					}
					elseif ((Test-SqlPath -SqlServer $destserver -Path $lastbackup[0].Path[0]) -eq $false)
					{
						Write-Message -Level Verbose -Message "SQL Server cannot find backup"
						$fileexists = $false
						$restoreresult = "Skipped"
						$dbccresult = "Skipped"
					}
					else
					{
						Write-Message -Level Verbose -Message "Looking good!"
						
						$fileexists = $true
						$ogdbname = $dbname
						$restorelist = Read-DbaBackupHeader -SqlServer $destserver -Path $lastbackup[0].Path
						$mb = $restorelist.BackupSizeMB

						if ($MaxMB -gt 0 -and $MaxMB -lt $mb)
						{
							$restoreresult = "The backup size for $dbname ($mb MB) exceeds the specified maximum size ($MaxMB MB)"
							$dbccresult = "Skipped"
						}
						else
						{
							$dbccElapsed = $restoreElapsed = $startRestore = $endRestore = $startDbcc = $endDbcc = $null
							
							$dbname = "$prefix$dbname"
							$destdb = $destserver.databases[$dbname]
							
							if ($destdb)
							{
								Stop-Function -Message "$dbname already exists on $destination - skipping" -Continue
							}
							
							if ($Pscmdlet.ShouldProcess($destination, "Restoring $ogdbname as $dbname"))
							{
								Write-Message -Level Verbose -Message "Performing restore"
								
								$startRestore = Get-Date
								if ($verifyonly)
								{
									$restoreresult = $lastbackup | Restore-DbaDatabase -SqlServer $destserver -RestoredDatababaseNamePrefix $prefix -DestinationFilePrefix $Prefix -DestinationDataDirectory $datadirectory -DestinationLogDirectory $logdirectory -VerifyOnly:$VerifyOnly
								}
								else
								{
									$restoreresult = $lastbackup | Restore-DbaDatabase -SqlServer $destserver -RestoredDatababaseNamePrefix $prefix -DestinationFilePrefix $Prefix -DestinationDataDirectory $datadirectory -DestinationLogDirectory $logdirectory
								}
								
								$endRestore = Get-Date
								$restorets = New-TimeSpan -Start $startRestore -End $endRestore
								$ts = [timespan]::fromseconds($restorets.TotalSeconds)
								$restoreElapsed = "{0:HH:mm:ss}" -f ([datetime]$ts.Ticks)
								
								if ($restoreresult.RestoreComplete -eq $true)
								{
									$success = "Success"
								}
								else
								{
									$success = "Failure"
								}
							}
							
							$destserver = Connect-SqlServer -SqlServer $destination -SqlCredential $DestinationCredential
							
							if (!$NoCheck -and !$VerifyOnly)
							{
								# shouldprocess is taken care of in Start-DbccCheck
								if ($ogdbname -eq "master")
								{
									$dbccresult = "DBCC CHECKDB skipped for restored master ($dbname) database"
								}
								else
								{
									if ($success -eq "Success")
									{
										Write-Message -Level Verbose -Message "Starting DBCC"
										
										$startDbcc = Get-Date
										$dbccresult = Start-DbccCheck -Server $destserver -DbName $dbname 3>$null
										$endDbcc = Get-Date
										
										$dbccts = New-TimeSpan -Start $startDbcc -End $endDbcc
										$ts = [timespan]::fromseconds($dbccts.TotalSeconds)
										$dbccElapsed = "{0:HH:mm:ss}" -f ([datetime]$ts.Ticks)
									}
									else
									{
										$dbccresult = "Skipped"
									}
								}
							}
							
							if ($VerifyOnly) { $dbccresult = "Skipped" }
							
							if (!$NoDrop -and $null -ne $destserver.databases[$dbname])
							{
								if ($Pscmdlet.ShouldProcess($dbname, "Dropping Database $dbname on $destination"))
								{
									Write-Message -Level Verbose -Message "Dropping database"
									
									## Drop the database
									try
									{
										$removeresult = Remove-SqlDatabase -SqlServer $destserver -DbName $dbname
										Write-Message -Level Verbose -Message "Dropped $dbname Database on $destination"
									}
									catch
									{
										Write-Message -Level Warning -Message "Failed to Drop database $dbname on $destination"
									}
								}
							}
							
							# Cleanup BackupFiles if -copyDestination and backup was moved to destination
							if($copyDestination -eq $true -and $($lastbackup.path).startswith($($destserver.BackupDirectory)))
							{
								Write-Message -Level Verbose -Message "Removing backup file from $destination"
								Remove-item $($lastbackup.fullname)
								$tempFolder = $lastbackup.fullname.Substring(0, $lastbackup.fullname.lastIndexOf('\'))
								if((get-childitem $tempFolder).count -eq 0)
								{
									Remove-item -Path $tempFolder
								} 
							}

					if ($destserver.Databases[$dbname] -ne $null -and !$NoDrop)
							{
								Write-Message -Level Warning -Message "$dbname was not dropped"
							}
						}
					}
					
					if ($Pscmdlet.ShouldProcess("console", "Showing results"))
					{
						[pscustomobject]@{
							SourceServer = $source
							TestServer = $destination
							Database = $db.name
							FileExists = $fileexists
							Size = [dbasize](($lastbackup.TotalSize | Measure-Object -Sum).Sum)
							RestoreResult = $success
							DbccResult = $dbccresult
							RestoreStart = [dbadatetime]$startRestore
							RestoreEnd = [dbadatetime]$endRestore
							RestoreElapsed = $restoreElapsed
							DbccStart = [dbadatetime]$startDbcc
							DbccEnd = [dbadatetime]$endDbcc
							DbccElapsed = $dbccElapsed
							BackupDate = $lastbackup.Start
							BackupFiles = $lastbackup.FullName
						}
					}
				}
			}
		}
	}
}
