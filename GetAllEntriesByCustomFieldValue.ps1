Function GetAllEntriesByCustomFieldValue{
    #Authenticate using RDM
    $ds = Get-RDMDataSource -Name "" #Change this to your datasource name in RDM.
    Set-RDMCurrentDataSource $ds

    #Go through all vaults and look for entries where CustomField1 is equal to CustomerName
    $Vaults = Get-RDMRepository
    Foreach ($v in $Vaults){
        Set-RDMCurrentRepository -Repository $v;
        Update-RDMUI;
        #I hardcoded CustomField1Value, this assumes CustomField1 is always used for CustomerNames. If required, you can add a loop for all 5 Custom Fields
        $Sessions = Get-RDMSession | Where-Object {($_.MetaInformation.CustomField1Value -eq 'CustomerName')}
        ForEach ($s in $Sessions ){
            #This will return the entry names. You could add an export to a CSV file in there.
            Write-Host $s.Name
        }
    }
}

