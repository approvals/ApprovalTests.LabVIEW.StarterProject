# ApprovalTests.LabVIEW.StarterProject

[![CI - Test&Build](../../actions/workflows/build.yml/badge.svg)](../../actions/workflows/build.yml)


This is a starter project for:

* [LabVIEW](https://www.ni.com/en-us/shop/labview.html)
* ApprovalTests in LabVIEW - see [ApprovalTests.LabVIEW](https://github.com/approvals/ApprovalTests.LabVIEW)
* [vipc](https://www.vipm.io/package/sas_workshops_lib_vipc_applier_for_g_cli/)
* [caraya](https://www.vipm.io/package/lvos_lib_caraya_cli_extension/)

Works on Windows. Might work on  Mac and Linux... 

Feel free to copy and go...

## Prerequisites

* [LabVIEW 2020](https://www.ni.com/en/support/downloads/software-products/download.labview.html) or later - the free Community Edition is fine.
* [VIPM](https://www.vipm.io/download/) installed
* [Beyond Compare](https://www.scootersoftware.com/) or [Winmerge](https://winmerge.org) (free alternative) installed and directory added to path.

## First Steps

1. Download the zip file (Under the code button in the top right).
2. Unzip
3. Install vipc file by doubleclicking on it and apply.
4. Open the Project.
5. Run the Tests (Tools -> Caraya -> Run All Tests in Project)
6. Once tests pass you are ready to go!

Notes:

* You will need a Diff tool.
* Suggestions: 
    * Windows: [WinMerge](winmerge.org/)
    * Mac: [DiffMerge](https://sourcegear.com/diffmerge/)
    * Linux: [meld](http://meldmerge.org/)

## GitHub Actions

LabVIEW will not work by default in a GitHub Action. You need to create a Custom Runner. We have an action set up in this repo. When you clone it, it won't work because it is pointed at our machine. Here is a [link to set up your own machine](https://sas-gcli-tools.gitlab.io/) if you want (optional - not required.) If you do, just tag it with `LV20x64` or change the tag in the job file.

## Need Help

Reach us [here](https://sasworkshops.com/contact)
