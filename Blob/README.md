## Files

* Sync-Repositories.ps1

Synchronizes an on-prem Update Retriever repository to an Azure Blob container. If the repository is configured as
a local repository, package XML descriptors for "reboot delayed" packages will be altered to "reboot required" to support a silent installation.

If the repository is configured as a cloud repository, no modifications will be made and the sync will follow.

AzCopy is installed from the Winget repository.

Authentication is handled using a SAS token.