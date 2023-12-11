import os
import shutil

def rename_contents(file_path, exceptions=('.png', '.jpg', '.dds', '.wav', '.ogg')):
    file_ending = os.path.splitext(file_path)[1]
    if file_ending not in exceptions:    
        # Read the original file contents
        with open(file_path, 'r', encoding='utf-8') as f:
            original_text = f.read()

        # Perform the replacements
        for k, v in MAP.items():
            original_text = original_text.replace(k, v)

        # Write the modified text back to the file
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write(original_text)


def rename(directory, new_directory, mappings):
    for root, dirs, files in os.walk(directory):
        for file in files:
            file_path = os.path.join(root, file)
            
            # Replace all file and directory names
            new_file = file
            new_root = root.replace(directory, new_directory)
            for key, rep in mappings.items():
                new_file = new_file.replace(key, rep)
                new_root = new_root.replace(key, rep)
            
            # Create new folder structure
            if not os.path.exists(new_root):
                os.makedirs(new_root)
            new_file_path = os.path.join(new_root, new_file)
            
            # Copy to new directory
            shutil.copy(file_path, new_file_path)
            
            # Rename content in files
            rename_contents(new_file_path)
            print(new_file_path)
  


MAP = {
    'vw': 'aw',
    'Vw': 'Aw',
    'VW': 'AW',
    'volkswagen': 'aw', # 'autowolf',
    'Volkswagen': 'AW', # 'Automobilwerke Wolfsburg',
    'VOLKSWAGEN': 'AW', # 'AUTOMOBILWERKE WOLFSBURG',
    'käfer': 'bug',
    'käfer': 'Bug',
    'KÄFER': 'BUG',
    'beetle': 'bug',
    'Beetle': 'Bug',
    'BEETLE': 'BUG',
    'herbie': 'herbert',
    'Herbie': 'Herbert',
    'HERBIE': 'HERBERT',
    'carello': 'carelu',
    'Carello': 'Carelu',
    'CARELLO': 'CARELU',
}

rename('.\\bug', '.\\bug_repo', MAP)
