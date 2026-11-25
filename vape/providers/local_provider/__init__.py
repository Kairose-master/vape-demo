"""Opt-in local inference gateway; no server, process, or downloads on import."""
from .service import LocalConfig, LocalGateway, RuntimeEvidence

__all__ = ['LocalConfig', 'LocalGateway', 'RuntimeEvidence']
