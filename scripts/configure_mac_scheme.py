#!/usr/bin/env python3
"""Xcode Run launches the canonical app installed by the aggregate build target."""
from pathlib import Path
import xml.etree.ElementTree as ET
root = Path(__file__).resolve().parents[1]
path = root / 'Orbit.xcodeproj/xcshareddata/xcschemes/OrbitMac.xcscheme'
tree = ET.parse(path)
for name in ['LaunchAction', 'ProfileAction']:
    action = tree.getroot().find(name)
    for child in list(action):
        if child.tag in ['BuildableProductRunnable', 'PathRunnable', 'MacroExpansion']:
            action.remove(child)
    ET.SubElement(action, 'PathRunnable', {'runnableDebuggingMode': '0', 'FilePath': '$(HOME)/Applications/Orbit Mac.app'})
    expansion = ET.SubElement(action, 'MacroExpansion')
    ET.SubElement(expansion, 'BuildableReference', {'BuildableIdentifier':'primary', 'BlueprintIdentifier':'CE69EDA42063C2C5BF35D021', 'BuildableName':'OrbitMac.app', 'BlueprintName':'OrbitMacClient', 'ReferencedContainer':'container:Orbit.xcodeproj'})
ET.indent(tree, space='   ')
tree.write(path, encoding='UTF-8', xml_declaration=True)
