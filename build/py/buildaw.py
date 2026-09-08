import os
import sys
import glob
import stat
import shutil
import session
from util import *

SourceFolder = "bug"
TargetFolder = "bug-aw"
ModFolder = "#mod"

meshFiles = [ "dae", "cdae" ]
textFiles = [ "txt", "json", "jbeam", "lua"]
codeFiles = [ "lua" ]

deleteFiles = [ "vehicles/bug/VariantID-*.json" ]

WordMap = {
    # Movie names: Just remove them entirely for now.
    '\"The Love Bug\" '                 : '',
    '\"Herbie Goes to Monte Carlo\" '   : '',
    '\"Herbie Goes Bananas\" '          : '',
    '\"Herbie: Fully Loaded\" '         : '',

    # Special strings
    'Volkswagen Type 1 \"Beetle\"'      : 'AW Type 1',      # Explicitly set the name.
    'Volkswagen Lettering'              : 'AW Lettering',   # The letterings just reads "AW" instead of the full name.
    
    # General strings
    'vw'        : 'aw',
    'Vw'        : 'Aw',
    'VW'        : 'AW',
    'volkswagen': 'aw', # 'autowolf',
    'Volkswagen': 'AW', # 'Automobilwerke Wolfsburg',
    'VOLKSWAGEN': 'AW', # 'AUTOMOBILWERKE WOLFSBURG',
    'käfer'     : 'bug',
    'Käfer'     : 'Bug',
    'KÄFER'     : 'BUG',
    'beetle'    : 'bug',
    'Beetle'    : 'Bug',
    'BEETLE'    : 'BUG',
    'herbie'    : 'curby', #'herbert', 
    'Herbie'    : 'Curby', #'Herbert', 
    'HERBIE'    : 'CURBY', #'HERBERT', 
    'carello'   : 'carelu',
    'Carello'   : 'Carelu',
    'CARELLO'   : 'CARELU',
}
IgnoreWords = [ '53_herbie_53' ]



def getFiles(path):
    return glob.glob(os.path.join(path, "**/*"), recursive=True)
#end

def getFilesByExt(path, extList):
    result = []
    for f in getFiles(path):
        if not os.path.isfile(f): continue
        ext = os.path.splitext(f)[1][1:] # also remove dot (.)
        for e in extList:
            if e.lower() == ext.lower(): result.append(f)
        #end
    #end

    return [f for f in result if not os.path.relpath(f, path).startswith(ModFolder)]
#end

def getRemovableFiles(path):
    # Determine files to be removed
    return [f for f in getFiles(path) if not os.path.relpath(f, path).startswith(ModFolder)]
#end

def copyFiles(source, target):
    shutil.copytree(source, target, dirs_exist_ok = True)
#end


def isDeleteFile(path, f):
    if not os.path.isfile(f): return False

    f = os.path.relpath(f, path)
    f = f.replace("\\", "/") 

    for pattern in deleteFiles:
        parts = pattern.split("*")

        if len(parts) == 1:
            if f == pattern: return True
            continue
        #end

        if not f.startswith(parts[0]) or not f.endswith(parts[-1]):
            continue

        ok = True
        for i in range(1, len(parts) - 1):
            if parts[i] not in f:
                ok = False
                break
            #end
        #end
        if ok: return True
    #end

    return False
#end
def getDeleteFiles(path):
    # Determine files to be removed
    return [f for f in getFiles(path) if isDeleteFile(path, f)]
#end

def applyWordMap(line):

    # Check if line contains any of the words to be replaced
    for k, v in WordMap.items():
        if not k in line: continue

        ignoreMap = {}
        ignoreIndex = 0
        for ignore in IgnoreWords:
            if not ignore in line: continue

            ignoreKey = f"⌈{ignoreIndex}⌉"  # Use a unique key for each ignore word
            ignoreMap[ignoreKey] = ignore
            ignoreIndex += 1

            line = line.replace(ignore, ignoreKey)
        #end

        line = line.replace(k, v)

        # Revert ignored words back to their original form
        for ignoreKey, ignore in ignoreMap.items():
            line = line.replace(ignoreKey, ignore)
        #end
    #end

    return line
#end

def findStringLiteral(line, startIndex=0):
    startPos = -1
    length = 0
    quoteChar = ''
    inString = False
    isEscaped = False

    for index in range(startIndex, len(line)):
        char = line[index]
        
        # Handle escaped characters
        if char == '\\' or isEscaped: 
            isEscaped = not isEscaped
            continue
        #end

        isQuote = char in ('"', "'")
        if isQuote and not inString:
            inString = True
            quoteChar = char
            startPos = index
            continue
        #end

        if not inString: continue
        if char == quoteChar and not isEscaped:
            length = index - startPos + 1
            break
        #end
    #end

    if not inString or length == 0:
        return (-1, 0, "")

    stringLiteral = line[startPos:startPos + length]
    return (startPos, length, stringLiteral)
#end

def processCode(line):
    startIndex = 0

    while True:
        pos, length, stringLiteral = findStringLiteral(line, startIndex)

        # No more string literals found
        if pos == -1 or length == 0: break

        # Relace words in string literals and update the line
        stringLiteral = applyWordMap(stringLiteral)
        line = line[:pos] + stringLiteral + line[pos + length:]

        # Update startIndex to continue searching after the current string literal
        startIndex = pos + len(stringLiteral)  
    #end

    return line
#end

def updateTextFile(file, wordmap):
    with open(file, 'r', encoding='utf-8') as f:
        content = f.read()
    #end

    isCode = os.path.splitext(file)[1][1:] in codeFiles

    content = content.replace("\r\n", "\n")  # Normalize line endings to LF
    content = content.replace("\r", "\n")     # Normalize line endings to LF

    lines = content.splitlines()
    changes = []

    for i in range(len(lines)):
        line = lines[i]
        if len(line) == 0: continue

        if isCode:
            line = processCode(line)
        else:
            line = applyWordMap(line)
        #end

        if line == lines[i]: continue

        # Line has changed, update it
        changes.append((lines[i], line)) 
        lines[i] = line
    #end

    if len(changes) == 0: return []

    content = "\n".join(lines) + "\n"  # Ensure the file ends with a newline

    with open(file, 'w', encoding='utf-8') as f:
        f.write(content)

    return changes
#end

def updateTextFiles(target, wordmap):
    for f in getFilesByExt(target, textFiles):
        changes = updateTextFile(f, wordmap)
        if len(changes) == 0: continue

        print(f"   Update '{os.path.relpath(f, root)}'")

        for k,v in changes:
            print(f"     -> {k.strip()}\n        {v.strip()}\n")
        #end
    #end
#end



def renameMeshFiles(target, prefix):
     for f in getFilesByExt(target, meshFiles):
        folder, name = os.path.split(f)

        # Skip files that already have the prefix
        if (name.startswith(prefix)): continue

        newName = f"{prefix}{name}"
        newPath = os.path.join(folder, newName)

        print(f"   Rename '{os.path.relpath(f, root)}'")

        if (os.path.exists(newPath)):
            print(f"     -> Warning: File '{newName}' already exists")
            continue
        #end
                        
        os.rename(f, newPath)
        print(f"     -> {name}\n        {newName}\n")
    #end
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

    if not session.init():
        return False

    root = session.root 

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

def printUsage(error=True):
    print("Usage: aw <command>")
    print("")
    print("  build           Builds the AW branded variant in 'bug-aw'.")
    print("")
    print("  clean           Only runs the clean step.")
    print("  copy            Only runs the copy step.")
    print("  apply           Only runs the apply step.")
    print("")
    return 2 if error else 0
#end

def printPaths():
    print(" Source: " + os.path.relpath(source, root))
    print(" Target: " + os.path.relpath(target, root))
    print("    Mod: " + os.path.relpath(mod, root))
#end

def clean():
    if not init(): return False

    print("- Clean folder ...")

    # Determine files to be removed
    items = getRemovableFiles(target)

    files = [f for f in items if os.path.isfile(f)]
    dirs = [d for d in items if os.path.isdir(d)]
    dirs.sort(key=lambda d: len(d), reverse=True)  # Sort directories by length in descending order

    errors = []
    for f in files:
        try:
            print(f"   Remove '{os.path.relpath(f, root)}'")
            os.chmod(f, stat.S_IWRITE)
            os.remove(f)
        except Exception as e:
            errors.append(f"Error while removing file '{f}': {e}")
    #end

    for d in dirs:
        try:
            #print(f"   Remove '{os.path.relpath(d, root)}'")
            os.chmod(d, stat.S_IWRITE)
            shutil.rmtree(d)
        except Exception as e:
            errors.append(f"Error while removing directory '{d}': {e}")
    #end

    if len(errors) == 0:
        print("  OK")
        return True
    #end

    print("  Errors occurred during cleaning:")
    for error in errors:
        print(f"   {error}")

    print("  Failed")
    return False
#end

def copy():
    if not init(): return False

    print("- Copy files ...")
    
    # copy files
    copyFiles(source, target)

    print("  OK")

    print("- Delete files ...")

     # Determine files to be removed
    files = getDeleteFiles(target)
    for f in files:
        print(f"   Remove '{os.path.relpath(f, root)}'")
        os.remove(f)
    #end

    print("  OK")

    print("- Rename files ...")

    renameMeshFiles(target, "AW-")

    print("  OK")
    return True
#end

def apply():
    if not init(): return False

    print("- Apply mod files ...")

    # overwrite vw with aw files
    copyFiles(mod, target)

    updateTextFiles(target, WordMap)

    print("  OK")
    return True
#end

def build():
    if not init(): return False

    printPaths()
    
    if not clean(): return False
    if not copy(): return False
    if not apply(): return False

    return True
#end

def processCommand(commands):
    cmd = popCommand(commands)

    if isCommand(cmd, "clean"):         return 0 if clean() else 1
    elif isCommand(cmd, "copy"):        return 0 if copy() else 1
    elif isCommand(cmd, "apply"):       return 0 if apply() else 1
    elif isCommand(cmd, "b", "build"):  return 0 if build() else 1

    return printUsage()
#end

def main(args=None, header=True):
    if not init(): return 1

    if args is None: args = sys.argv
    if hasCommandHelp(args): return printUsage(False)
    if len(args) != 2: return printUsage()

    if header: print("Root: " + root)
    return processCommand(args[1:])
#end

if __name__ == '__main__':
    sys.exit(main())