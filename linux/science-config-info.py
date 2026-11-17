from pathlib import Path
import science_integrity
science_integrity.verify(Path(__file__).resolve().parent)
import science_config
print('Edit ScientificPackages in: ' + str(science_config.active_path()))
print('On first installation the file is created after existing-environment detection. Existing configuration is never inferred from installed packages.')
