import sys
import os
print(sys.executable)
try:
    import grpc
    print("grpc found at:", grpc.__file__)
except ImportError:
    print("grpc not found")
