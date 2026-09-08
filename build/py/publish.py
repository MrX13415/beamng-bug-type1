import os
import sys
import glob
import shutil
import zipfile
import session
from util import *
from dataclasses import dataclass

# ID : FolderName
VariantIDMap = {
    "vw" : "bug",
    "aw" : "bug-aw"
}

IgnoreFolders = [ "#mod" ]

def makeZIP(srcPath, targetPath):
    if not session.init(): return False

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

    return os.path.exists(target)
#end

@dataclass
class ModInfo:
    name: str = ""
    version: tuple[int, int] = (0, 0)
    date: str = ""
    variantID: str = ""

    def versionStr(self) -> str:
        if self.version[1] == 0: return f"{self.version[0]}"
        return f"{self.version[0]}.{self.version[1]}" 
    #end

    def toString(self) -> str:
        out = "Mod Information\n"
        out += f"        Name: {self.name}\n"
        out += f"     Version: {self.versionStr()}\n"
        out += f"        Date: {self.date}\n"
        out += f"  Variant-ID: {self.variantID}\n"
        return out
    #end
#end

def getModInfo(variantID="vw"):
    if not session.init(): return None

    source = os.path.join(session.root, VariantIDMap[variantID])
    file = os.path.join(source, "vehicles/bug/lua/mod.lua")
    if not os.path.exists(file): return None

    with open(file, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    #end
   
    name = None    
    version = None
    date = None 
    id = None

    def lineStr(line):
        a = line.find("\"")
        b = line.rfind("\"", a)
        if a > 0 and b > a:
            return line[a+1:b]
        return ""
    #end
    def lineVersion(line):
        a = line.find("{")
        b = line.find(",", a+1)
        c = line.find("}", b+1)
        if a > 0 and b > a and c > b:
            return (int(line[a+1:b]), int(line[b+1:c]))
        return (0, 0)
    #end


    for line in lines:
        # local _name = "Volkswagen Type 1 \"Beetle\""
        # local _version = {27, 1}
        # local _versionDate = "2026-08-21"
        # local _variantID = "VW"

        if "local" not in line and "=" not in line: continue

        if "_name" in line and name is None:
            name = lineStr(line)
        elif "_versionDate" in line and date is None:
            date = lineStr(line)
        elif "_version" in line and version is None:
            version = lineVersion(line)
        elif "_variantID" in line and id is None:
            id = lineStr(line)
        elif "function " in line and "(" in line and ")" in line:
            break # Functions section reached!
        #end       
    #end

    info = ModInfo(name, version, date, id)
    return info
#end

@dataclass
class ResultInfo:
    filename: str = ""
    info: ModInfo = None
    githash: str = None
    gitbranch: str = None
#end

def getResultInfo(variantID):
    info = getModInfo(variantID)
    verStr = f"-{info.versionStr()}" if info.version != 0 else ""
    hash = gitCommitHash()
    hashStr = f"+{hash}" if hash is not None else ""
    branch = gitBranch()
    branchStr = f"-{sanitizeFilename(branch)}" if branch is not None else ""

    filename = f"Publish/release-{variantID}{verStr}{hashStr}{branchStr}.zip"

    result = ResultInfo(filename, info, hash, branch)
    return result
#end

def publish(variantID, githubOutputs=False):
    variantID = variantID.strip().lower()
    if not variantID in VariantIDMap:
        print(f"Error: Unknown variantID '{variantID}'")
        return False
    #end

    resultInfo = getResultInfo(variantID)
    resultFile = resultInfo.filename

    print("Publish Variant: " + variantID.upper())
    print(f"File: {resultFile}")

    ok = makeZIP(VariantIDMap[variantID], resultFile)

    if ok and githubOutputs:
        data={
            "commit": resultInfo.githash,
            "branch": resultInfo.gitbranch,
            "resultfile": resultInfo.filename,
            "version": resultInfo.info.versionStr(),
            "variantid": resultInfo.info.variantID
        }
        if writeGithubOutputs(data):
            print("GitHub Outputs written")
        else:
            print("Error: Unable to write GitHub Outputs!")
    #end

    print()
    return ok
#end

def printUsage(error=True):
    print("Usage: publish [options] <variantID>")
    print("")
    print("  variantID       Publishs the variant with the given ID.")    
    print("")
    print("  --github        Writes result infromation into the GitHub Outpus file.")
    print("Variant IDs: " + ", ".join(VariantIDMap.keys()))
    return 2 if error else 0
#end

def processCommand(commands):
    sws = popCommandSwitchs(commands)
    cmd = popCommand(commands)

    github = "github" in sws

    if len(cmd) > 0:    return 0 if publish(cmd, github) else 1

    return printUsage()
#end

def main(args=None, header=True):
    if not session.init(): return 1

    if args is None: args = sys.argv
    if hasCommandHelp(args): return printUsage(False)
    if len(args) < 2: return printUsage()

    if header: print("Root: " + session.root)
    return processCommand(args[1:])
#end

if __name__ == '__main__':
    sys.exit(main())