import os
import sys
import subprocess
import re

def dirname(path: str, index: int = 0) -> str:
    for i in range(index+1):
        path = os.path.dirname(path)
    return path
#end

def fileCount(folder: str) -> int:
    count = 0
    for root, dirs, files in os.walk(folder):
        count += len(files)
    #end
    return count
#end

def sanitizeFilename(filename: str, replacement: str = "_") -> str:
    illegalChars = r'[\/:*?"<>|]'
    cleanName = re.sub(illegalChars, replacement, filename)
    return cleanName
#end

def asCommand(rawInput) -> str:
    return str(rawInput).lower().strip()
#end
def getCommands(rawInput) -> list[str]:    
    entires = rawInput if type(rawInput) == list else str(rawInput).split()
    return [asCommand(e) for e in entires]
#end
def popCommand(commands, index=0) -> str:
    return commands.pop(index) if len(commands) > 0 else ""
#end
def fullCommands(commands) -> list:
    return [ sys.argv[0] ] + commands
#end
def isCommandSwitch(command) -> tuple[bool, str]:
    if len(command) < 2: return (False, "")
    a = command[0:1]    
    b = command[1:2]
    name = command[1:]

    if a != "/" and a != "-": return (False, "")
    if b.isalnum(): return (True, name)

    while len(name) > 0 and name[0:1] == "-":
        name = name[1:]

    return (len(name) > 0, name)
#end
def popCommandSwitchs(commands) -> list[tuple[bool, str]]:
    commandsNew = []
    switches = []
    
    for c in commands:
        ok, name = isCommandSwitch(c)
        if ok: switches.append(name)
        else: commandsNew.append(c)

    # Use [:] to modify the original list in-place
    commands[:] = commandsNew
    return switches
#end
def isCommand(var, *matches) -> bool:
    var = asCommand(var)
    for c in matches:
        if var == asCommand(c): return True
    #end
    return False
#end
def isCommandHelp(command) -> bool:
    cmd = command.strip().lower()
    _, sw = isCommandSwitch(cmd)
    return isCommand(cmd, "help", "h", "?") or isCommand(sw, "help", "h", "?")
#end
def hasCommandHelp(commands) -> bool:
    for cmd in commands:
        if isCommandHelp(cmd): return True
    return False
#end

def gitCommitHash() -> str:
    # When running inside GitHub Actions:
    if "GITHUB_SHA" in os.environ:
        return os.environ["GITHUB_SHA"][:7] 
        
    # Fallback to local Git
    try:
        return subprocess.check_output(['git', 'rev-parse', '--short', 'HEAD']).decode('ascii').strip()
    except subprocess.CalledProcessError:
        return None
#end

def gitBranch() -> str:
    # When running inside GitHub Actions:
    if "GITHUB_REF_NAME" in os.environ:
        return os.environ["GITHUB_REF_NAME"]
        
    # Fallback to local Git
    try:
        # Runs: git branch --show-current
        branch = subprocess.check_output(['git', 'branch', '--show-current']).decode('utf-8').strip()
        
        # If Git is in a "Detached HEAD" state (e.g. looking at a raw commit hash), 
        # --show-current returns nothing. We handle that fallback here:
        return branch if branch else "detached-head"
    
    except subprocess.CalledProcessError:
        return None
#end

def writeGithubOutputs(outputs: dict[str, str | int | float], overwrite: bool = False) -> bool:
    """Appends a dictionary of key-value pairs to the GitHub Actions output file.
    
    Does nothing if running locally outside of GitHub Actions.
    """
    githubOutputPath = os.environ.get("GITHUB_OUTPUT")
    
    if not githubOutputPath:
        return False

    mode = "w" if overwrite else "a"
    with open(githubOutputPath, mode, encoding="utf-8") as f:
        for key, value in outputs.items():
            f.write(f"{key}={value}\n")
    #end
    return True
#end
