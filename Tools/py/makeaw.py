import os
import sys
import glob
import shutil
import session
from util import *

SourceFolder = "bug"
TargetFolder = "bug-aw"
ModFolder = "#mod"


def getFiles(path):
    return glob.glob(os.path.join(path, "**/*"), recursive=True)
#end
def getRemovableFiles(path):
    # Determine files to be removed
    return [f for f in getFiles(path) if not os.path.relpath(f, path).startswith(ModFolder)]
#end
def copyFiles(source, target):
    shutil.copytree(source, target, dirs_exist_ok = True)
#end

__init = False
root = ""
source = ""
target = ""
mod = ""


def init():
    global __init
    global root
    global source
    global target
    global mod

    if __init: return True

    source = ""
    target = ""
    mod = ""

    root = session.root #   dirname(os.path.realpath(__file__), 2)       # Get the second parent folder
    
    #debug: root = os.path.join(root, "x")

    # Root path correct?
    if not os.path.exists(os.path.join(root, SourceFolder)):
        print("Error: Root path does not contain expected folders.")
        return False
    #end

    source = os.path.join(root, SourceFolder)
    target = os.path.join(root, TargetFolder)
    mod = os.path.join(target, ModFolder)

    __init = True
    return True
#end

def printUsage():
    print("Usage: makeaw clean|copy|apply|build")
#end

def printPaths():
    print(" Source: " + os.path.relpath(source, root))
    print(" Target: " + os.path.relpath(target, root))
    print("    Mod: " + os.path.relpath(mod, root))
#end

def clean():
    if not init(): return

    print("- Clean folder ...")

    # Determine files to be removed
    files = getRemovableFiles(target)

    for f in files:
        if not os.path.isfile(f): continue
        print(f"   Remove '{os.path.relpath(f, root)}'")
        os.remove(f)
    #end

    for d in files:
        if not os.path.isdir(d): continue
        shutil.rmtree(d)
    #end

    print("  OK")
#end

def copy():
    if not init(): return

    print("- Copy files")
    
    # copy files
    copyFiles(source, target)

    print("  OK")
#end

def apply():
    if not init(): return

    print("- Apply mod files")

    # overwrite vw with aw files
    copyFiles(mod, target)

    print("  OK")
#end

def build():
    if not init(): return

    printPaths()
    
    clean()
    copy()
    apply()
#end

def processCommand(commands):
    cmd = popCommand(commands)

    if cmd == "clean": clean()
    elif cmd == "copy": copy()
    elif cmd == "apply": apply()
    elif cmd == "build": build()
    else: 
        printUsage()
        return
    #end
#end

def main():
    if not init(): return
    
    if len(sys.argv) != 2:
        printUsage()
        return
    #end

    print("   Root: " + root)
    processCommand([asCommand(sys.argv[1])])
#end

if __name__ == '__main__':
    main()