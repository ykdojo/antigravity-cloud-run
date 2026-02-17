---
name: gdoc
description: Read publicly shared Google Docs using curl to download into a file.
---

# Google Docs Reader

To read a Google Doc:

1. Replace `/edit` (or any suffix after the doc ID) with `/mobilebasic`
2. Use curl to download into a file (don't use WebFetch - curl gets the full content):

```bash
curl -sL 'https://docs.google.com/document/d/DOC_ID/mobilebasic' > /tmp/doc.txt
```

3. Read the downloaded file with the Read tool
