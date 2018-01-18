﻿$CommandName = $MyInvocation.MyCommand.Name.Replace(".Tests.ps1", "")
Write-Host -Object "Running $PSCommandpath" -ForegroundColor Cyan
. "$PSScriptRoot\constants.ps1"
$script:instance2 = "sql2017"
Describe "$commandname Integration Tests" -Tags "IntegrationTests" {
    AfterAll {
        $null = Get-DbaXESession -SqlInstance $script:instance2 -Session 'Overly Complex Queries' | Remove-DbaXESession
    }
    Context "Test Importing Session Template" {
        $result = Import-DbaXESessionTemplate -SqlInstance $script:instance2 -Template 'Overly Complex Queries' -TargetFilePath C:\temp
        It "session imports with proper name and non-default target file location" {
            $result.Name | Should Be "Overly Complex Queries"
            $result.TargetFile -match 'C\:\\temp' | Should Be $true
        }
    }
}