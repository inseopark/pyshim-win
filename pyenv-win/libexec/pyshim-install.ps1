#requires -V 5.1
# pyshim-install.ps1

$script:dp0 = $PSScriptRoot
$script:parent_path = Split-Path $dp0
$script:workingdir = Get-Location


if (!$Global:g_pyshim_flag_commonlib_loaded) {
    Import-Module "$parent_path\lib\commonlib.ps1" -Force
    Write-Verbose "($(__FILE__):$(__LINE__)) Common lib not loaded .. loading..."
}

$script:nuget_bin           = [IO.Path]::Combine($Global:g_global_externals_path , "nuget.exe")
$script:7z_bin              = [IO.Path]::Combine($Global:g_global_externals_path , "7za.exe")
$script:build_pythonx86_bin = [IO.Path]::Combine($Global:g_global_build_plugin_path, "pythonx86", "Tools", "python.exe")
$script:build_unpacker      = [IO.Path]::Combine($Global:g_global_build_plugin_path, "pyshim_unpack.py")
$script:pyshim_builder      = [IO.Path]::Combine($Global:g_global_build_plugin_path, "pyshim_build.bat")
$script:min_buildable_version ='3.6.3'

function script:Check_Externals() {

    if (-not (Test-Path $script:nuget_bin)) {
        Write-Host "nuget missing, installing nuget ..."
        & ([IO.Path]::Combine($g_pyshim_libexec_path, "get_externals.ps1")) 'nuget'
    }
<#
    if (-not (Test-Path $script:7z_bin)) {
        Write-Host "7za missing, installing 7za  ..."
        & ([IO.Path]::Combine($g_pyshim_libexec_path, "get_externals.ps1")) '7za'
    }
#>
    

}

Function script:Build_Python($build_version) {
    $fetch_url  = "https://www.python.org/ftp/python/$($build_version)/Python-$($build_version).tar.xz"
    $dest_file  =  [IO.Path]::Combine($Global:g_python_build_path, "Python-" + $build_version + ".tar.xz")
    $build_path = [IO.Path]::Combine($Global:g_python_build_path, "Python-" + $build_version)
    Write-Verbose "($(__FILE__):$(__LINE__)) url to download: $fetch_url"
    Write-Verbose "($(__FILE__):$(__LINE__)) dest file      : $dest_file"

    #pythonx86 for build install
    if (-Not (Test-Path $build_pythonx86_bin)) {
        Write-Verbose "($(__FILE__):$(__LINE__)) pythonx86 for build not available"
        $call_args = "install pythonx86 -ExcudeVersion -o `"$($Global:g_python_build_path)`""
        Invoke-Expression  "& `"$nuget_bin`" $call_args"
     }
    
    if (-Not (Test-Path $g_python_build_path)) {
        Write-Verbose "($(__FILE__):$(__LINE__)) $g_python_build_path not existing creating..."
        New-Item -ItemType Directory -Force -Path $g_python_build_path > $null
    }

    if (Test-Path $build_path) {

        Write-Host "source already exist, skipping download..."

    } elseif (-Not (Test-Path($dest_file))) {
        Write-Host "Downloading Python-$build_version.tar.xz ..."
        Write-Host "-> $fetch_url"
        Invoke-WebRequest $fetch_url -OutFile $dest_file

        if (-Not (Test-Path $dest_file)) {
            Write-Host "failed to download python src file from  $fetch_url"
            return
        } 
        
        $call_args = "$($script:build_unpacker) --file $dest_file --dest $($Global:g_python_build_path)"
        Invoke-Expression  "& `"$build_pythonx86_bin`" $call_args"
        Write-Verbose "($(__FILE__):$(__LINE__)) unextact called $call_args"

    } 

    if (Test-Path $build_path) {


        Write-Host "Building Python-$build_version"
        $call_args = "-x64 --src `"$($build_path)`""
        Invoke-Expression  "& `"$pyshim_builder`" $call_args"
    }

}

Function script:Nuget_Install($build_version) {
    # nuget install python -Version 3.6.3 -NoCache -NonInteractive -OutputDirectory ..

    $call_args = "install python -Version $($build_version) -NonInteractive -OutputDirectory `"$($Global:g_pyshim_versions_path)`""


    Invoke-Expression  "& `"$nuget_bin`" $call_args"

    Write-Verbose "($(__FILE__):$(__LINE__)) nuget exit code : $LastExitCode"
    $nupkg_path = [IO.Path]::Combine($Global:g_pyshim_versions_path, "python." + $build_version)

    if (($LastExitCode -ne 0) -or (-Not( Test-Path $nupkg_path))) {

        Write-Host "failed during install via nuget version : $build_version, try --build option if possible"
    } else {
        # rename directory
        Rename-Item $nupkg_path ([IO.Path]::Combine($Global:g_pyshim_versions_path, $build_version)) 
        #remove unnecessary *.nupkg
        Remove-Item ([IO.Path]::Combine($Global:g_pyshim_versions_path, $build_version, "*.nupkg"))
    }
}


function script:Main($argv) {

    $sopts = "lfskvg"
    $loptions = @("list", "force", "file=", "skip-existing", "keep", "verbose", "version" , "debug", "build", "verbose")
    Check_Externals
    <#

    Usage: pyenv install [-f] [-kvp] <version>
       pyenv install [-f] [-kvp] <definition-file>  ### not supported ###
       pyenv install -l|--list
       pyenv install --version

    -l/--list          List all available versions (not yet implemented)
    -f/--force         Install even if the version appears to be installed already
    -s/--skip-existing Skip if the version appears to be installed already

    python-build options:

    -k/--keep          Keep source tree in $PYENV_BUILD_ROOT after installation
                        (defaults to $PYENV_ROOT/sources)
    -p/--patch         Apply a patch from stdin before building
    -v/--verbose       Verbose mode: print compilation status to stdout
    --version          Show version of python-build
    -g/--debug         Build a debug version
    #>

    $opts, $remains, $errmsg = getargs $argv $sopts $loptions



    #region checking nuget external exists
    if (Test-Path $Global:g_global_python_version_file) {
        Write-Verbose ( "($(__FILE__):$(__LINE__)) checking global python version in " + $Global:g_global_python_version_file)
        # first version in version file is python global version
        $python_version = (Get-Content -Path $Global:g_global_python_version_file -TotalCount 1).Trim()
    }
    Write-Verbose "($(__FILE__):$(__LINE__)) current global version :  $python_version"
    #endregion

    $requested_version = $remains[0];
    # regex pattern created by https://regexr.com/39s32 jc@jmccc.com
    #$pattern_version = '^((([0-9]+)\.([0-9]+)\.([0-9]+)(?:-([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?)(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?)$'
    #$requested_version -match $pattern_version 

    $o_version =  Get-PyVersionNo ($requested_version)
    $st_version = "$($o_version.Major).$($o_version.Minor).$($o_version.Patch)"

    if (Test-Path ([IO.Path]::Combine( $Global:g_pyshim_versions_path, $st_version))) {

        if ($opts.f -or $opts.force) {
            $del_tree = [IO.Path]::Combine( $Global:g_pyshim_versions_path, $st_version)
            Write-Host "Force install option triggered... deleting $del_tree"
            Remove-Item -Path $del_tree -Force -Recurse

        } else {
            Write-Host "Version : $st_version already installed"
            return;
        }
    }

    if ($opts.build) {
        if ([version]$st_version -ge [version]$min_buildable_version) {
            Write-Host "Version : $($o_version.Major).$($o_version.Minor).$($o_version.Patch) to be built"
            Build_Python ($st_version)
        } else {
            Write-Host "Unable to build, supported version : >= $min_buildable_version"

        }
    } else {
        Write-Host "Version : $st_version to be installed via nuget "
        Nuget_Install($st_version)
    }
    


    
}

script:Main($args)