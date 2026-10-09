import pathlib

import pytest

ROOT = pathlib.Path(__file__).resolve().parent.parent
ROLE = ROOT / "ansible" / "roles" / "incus-host"


@pytest.fixture(scope="session")
def root():
    return ROOT


@pytest.fixture(scope="session")
def role():
    return ROLE
