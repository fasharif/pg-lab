"""Exceptions with messages meant for the person running the lab."""


class LabError(Exception):
    """A problem the user can fix (configuration, missing data, invalid definitions)."""


class CheckError(LabError):
    """One or more plan or drill assertions failed."""
