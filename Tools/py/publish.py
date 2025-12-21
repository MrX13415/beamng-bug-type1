import os
import sys
import glob
import shutil
import zipfile
import session
from util import *

VariantIDMap = {
    "vw" : "bug",
    "aw" : "bug-aw"
}

IgnoreFolders = [ "#mod" ]

def makeZIP(srcPath, targetPath):

    source = os.path.join(session.root, srcPath)
    target = os.path.join(session.root, targetPath)
    
    if os.path.exists(target):
        os.remove(target)

    print(f"Compressing '{targetPath}'")
    count = fileCount(source)
    index = 0

    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED, allowZip64=True) as zf:
        for root, dirs, files in os.walk(source):
            
            skip = False
            folder = os.path.relpath(root, source) 
            for ignore in IgnoreFolders:
                if folder.startswith(ignore): 
                    skip = True
                    break
                #end
            #end

            if skip:
                index += len(files)
                continue
            #end

            for file in files:
                path = os.path.join(root, file)
                name = os.path.relpath(path, source)

                index += 1
                p = (index/count)*100
                print(f"{p:5.1f}% {index:4}/{count}: {name}")
                zf.write(path, name)
            #end
        #end
    #end
    print("Done")
    print("")
#end


def publish(variantID):
    variantID = variantID.strip().lower()
    if not variantID in VariantIDMap:
        print(f"Error: Unknown variantID '{variantID}'")
        return False
    #end

    print("Publish Variant: " + variantID.upper())
    print()

    makeZIP(VariantIDMap[variantID], f"Publish\\release-{variantID}.zip")
#end

def printUsage():
    print("Usage: publish <variantID>")
    print("")
    print("  variantID       Publishs the variant with the given ID.")
    print("")
    print("Variant IDs: " + ", ".join(VariantIDMap.keys()))
#end

def processCommand(commands):
    cmd = popCommand(commands)

    if len(cmd) > 0:
        publish(cmd)
    else: 
        printUsage()
        return
    #end
#end


def main():
    if len(sys.argv) != 2:
        printUsage()
        return
    #end

    print("   Root: " + session.root)
    processCommand([asCommand(sys.argv[1])])
#end

if __name__ == '__main__':
    main()