from setuptools import setup, find_packages

with open("README.md", "r", encoding="utf-8") as fh:
    long_description = fh.read()

setup(
    name="azure-arc-framework",
    version="1.0.0",
    author="Project Contributor",
    author_email="contributor@example.com",
    description="A comprehensive framework for Azure Arc deployment and management",
    long_description=long_description,
    long_description_content_type="text/markdown",
    url="https://github.com/project-owner/azure-arc-framework",
    packages=find_packages(where="src"),
    package_dir={"": "src"},
    classifiers=[
        "Development Status :: 4 - Beta",
        "Intended Audience :: System Administrators",
        "Programming Language :: Python :: 3",
        "Programming Language :: Python :: 3.8",
        "Programming Language :: Python :: 3.9",
        "Programming Language :: PowerShell",
        "License :: OSI Approved :: MIT License",
        "Operating System :: Microsoft :: Windows",
        "Topic :: System :: Systems Administration",
    ],
    python_requires=">=3.8",
    install_requires=[
        "numpy>=1.19.0",
        "pandas>=1.3.0",
        "scikit-learn>=0.24.0",
        "azure-mgmt-hybridcompute>=7.0.0",
        "azure-mgmt-monitor>=3.0.0",
        "azure-identity>=1.7.0",
        "PyYAML>=5.4.1",
    ],
    extras_require={
        'dev': [
            'pytest>=6.0.0',
            'pytest-cov>=2.12.0',
            'black>=21.5b2',
            'flake8>=3.9.0',
            'mypy>=0.910',
        ],
        'optional': [
            'matplotlib>=3.4.0',
            'seaborn>=0.11.0',
            'jupyter>=1.0.0',
        ],
    },
)