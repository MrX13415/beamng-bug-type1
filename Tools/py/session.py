import os
from util import *

__init = False
root = ""

def init():
    global __init
    global root

    if __init: return True
    root = dirname(os.path.realpath(__file__), 2)       # Get the second parent folder
    
    # Root path correct?
    if not os.path.exists(os.path.join(root, "bug")):
        print("Error: Root path does not contain expected folders.")
        return False
    #end

    __init = True
    return __init
#end