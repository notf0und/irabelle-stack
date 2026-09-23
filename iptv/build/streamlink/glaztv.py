"""
$description Russian online TV streaming platform with dynamic streams
$url glaz.tv
$type live
"""

import logging
import re

from streamlink.exceptions import NoStreamsError
from streamlink.plugin import Plugin, pluginmatcher
from streamlink.stream.hls import HLSStream


log = logging.getLogger(__name__)


@pluginmatcher(re.compile(
    r"https?://(?:www\.)?glaz\.tv/online-tv/(?P<channel>\w+(?:-\w+)*)"
))
class GlazTV(Plugin):
    """
    Glaz.tv plugin for Streamlink
    Extracts HLS streams from glaz.tv online TV channels
    Supports dynamic token-based streams using wmsAuthSign signatures
    """
    
    # Known Nimble streaming servers for glaz.tv
    # These servers host the actual HLS streams
    NIMBLE_SERVERS = [
        "s209.glaz.tv",
        "s208.glaz.tv",
        "s210.glaz.tv",
    ]
    
    def _get_streams(self):
        """Extract HLS stream from glaz.tv"""
        channel = self.match.group("channel")
        log.info(f"Fetching stream for channel: {channel}")
        
        try:
            # Fetch the page content
            res = self.session.http.get(self.url, timeout=10, verify=False)
            res.raise_for_status()
            
            # Extract stream URL from page
            stream_url = self._extract_stream_url(res.text, channel)
            
            if not stream_url:
                log.error(f"Could not find stream URL for {channel}")
                raise NoStreamsError()
            
            log.info(f"Found stream URL for {channel}")
            
            # Parse the variant playlist to get the actual streams
            return HLSStream.parse_variant_playlist(self.session, stream_url)
            
        except NoStreamsError:
            raise
        except Exception as e:
            log.error(f"Error fetching stream for {channel}: {e}")
            raise NoStreamsError()
    
    def _extract_stream_url(self, html, channel):
        """
        Extract HLS stream URL from HTML content
        
        Glaz.tv uses Nimble streaming with wmsAuthSign authentication.
        The page contains:
        - streamPath: the stream path (e.g., 'muztv.stream/playlist.m3u8')
        - signature (wmsAuthSign): authentication token
        
        Constructs URL like:
        https://s209.glaz.tv:8082/liveg/{streamPath}?wmsAuthSign={signature}
        """
        
        try:
            # Extract streamPath (e.g., 'muztv.stream/playlist.m3u8')
            stream_path_match = re.search(r"var streamPath = '([^']+)'", html)
            if not stream_path_match:
                log.warning("Could not find streamPath variable")
                return None
            
            stream_path = stream_path_match.group(1)
            log.debug(f"Found streamPath: {stream_path}")
            
            # Extract wmsAuthSign signature
            # Can be named 'signature', 'cdnSignature', or 'wmsAuthSign'
            sign_match = re.search(r"var (?:signature|cdnSignature|wmsAuthSign) = ['\"]([^'\"]+)['\"]", html)
            if not sign_match:
                log.warning("Could not find authentication signature")
                return None
            
            signature = sign_match.group(1)
            log.debug(f"Found signature: {signature[:20]}...")
            
            # Construct HLS URL using Nimble server
            # Format: https://{server}:8082/liveg/{streamPath}?wmsAuthSign={signature}
            server = self.NIMBLE_SERVERS[0]  # Use primary server
            stream_url = f"https://{server}:8082/liveg/{stream_path}?wmsAuthSign={signature}"
            
            log.debug(f"Constructed URL: {stream_url[:100]}...")
            
            # Validate it looks like a valid HLS URL
            if '.m3u8' in stream_url and 'glaz.tv' in stream_url:
                return stream_url
            
            log.warning(f"Constructed URL doesn't look valid: {stream_url[:100]}")
            return None
            
        except Exception as e:
            log.error(f"Error extracting stream URL: {e}")
            return None


__plugin__ = GlazTV
