"""
Pyright LSP Demo - Python Type Checking Examples
================================================

This file demonstrates what the Pyright Language Server Protocol (LSP) can detect.
Pyright is a static type checker for Python that provides real-time feedback in your editor.

Each section below shows different categories of errors and valid code that LSP validates.
"""

# ============================================================================
# 1. TYPE ERRORS - Passing wrong types to functions
# ============================================================================

def greet(name: str) -> str:
    """Function that expects a string parameter."""
    return f"Hello, {name}!"


# ✓ VALID: Passing correct type
result1: str = greet("Alice")

# ✗ LSP ERROR: Type error - passing int instead of str
result2: str = greet(42)  # Pyright: Expected 'str', got 'int'

# ✗ LSP ERROR: Type error - passing list instead of str
result3: str = greet(["Alice"])  # Pyright: Expected 'str', got 'list[str]'


def add_numbers(a: int, b: int) -> int:
    """Function that expects integers."""
    return a + b


# ✓ VALID: Correct types
sum1: int = add_numbers(5, 10)

# ✗ LSP ERROR: Type error - passing float instead of int
sum2: int = add_numbers(5.5, 10)  # Pyright: Expected 'int', got 'float'

# ✗ LSP ERROR: Type error - passing string instead of int
sum3: int = add_numbers("5", 10)  # Pyright: Expected 'int', got 'str'


# ============================================================================
# 2. UNDEFINED VARIABLES
# ============================================================================

# ✗ LSP ERROR: Undefined variable
print(undefined_variable)  # Pyright: 'undefined_variable' is not defined

# ✗ LSP ERROR: Undefined variable in assignment
x = undefined_var + 10  # Pyright: 'undefined_var' is not defined

# ✓ VALID: Properly defined variable
defined_var = 42
y = defined_var + 10


# ============================================================================
# 3. MISSING IMPORTS
# ============================================================================

# ✓ VALID: Proper import
import os
current_dir = os.getcwd()

# ✗ LSP ERROR: Using non-existent module
import nonexistent_module  # Pyright: Cannot access member 'nonexistent_module'

# ✗ LSP ERROR: Using non-existent function from a module
from os import nonexistent_function  # Pyright: Cannot access member 'nonexistent_function'

# ✗ LSP ERROR: Using undefined module attribute
result = os.nonexistent_method()  # Pyright: Cannot access member 'nonexistent_method'


# ============================================================================
# 4. INCORRECT FUNCTION SIGNATURES
# ============================================================================

def filter_data(data: list[int], threshold: int = 10) -> list[int]:
    """Function with specific parameter requirements."""
    return [x for x in data if x > threshold]


# ✓ VALID: Correct number and types of arguments
filtered1 = filter_data([1, 5, 15, 20], 10)

# ✓ VALID: Using default parameter
filtered2 = filter_data([1, 5, 15, 20])

# ✗ LSP ERROR: Missing required positional argument
filtered3 = filter_data()  # Pyright: Missing argument for parameter 'data'

# ✗ LSP ERROR: Too many positional arguments
filtered4 = filter_data([1, 5, 15], 10, "extra")  # Pyright: Expected 1-2 positional arguments

# ✗ LSP ERROR: Wrong type for named parameter
filtered5 = filter_data([1, 5, 15], threshold="10")  # Pyright: Expected 'int', got 'str'


def multi_param(a: str, b: int, c: bool) -> None:
    """Function with multiple parameters of different types."""
    pass


# ✓ VALID: Correct types in correct order
multi_param("text", 42, True)

# ✗ LSP ERROR: Wrong types in wrong positions
multi_param(42, "text", True)  # Pyright: Expected 'str', got 'int'


# ============================================================================
# 5. GOOD CODE WITH TYPE HINTS (LSP Validates Correctly)
# ============================================================================

from typing import Optional, List, Dict, Union


def calculate_average(numbers: List[float]) -> float:
    """
    Calculate the average of a list of numbers.

    Args:
        numbers: List of numbers to average

    Returns:
        The average value
    """
    if not numbers:
        return 0.0
    return sum(numbers) / len(numbers)


# ✓ VALID: All types match correctly
nums: List[float] = [10.5, 20.3, 15.7]
avg: float = calculate_average(nums)


def find_user(user_id: int) -> Optional[Dict[str, str]]:
    """
    Find a user by ID.

    Args:
        user_id: The user's ID

    Returns:
        User data dictionary or None if not found
    """
    users: Dict[int, Dict[str, str]] = {
        1: {"name": "Alice", "email": "alice@example.com"},
        2: {"name": "Bob", "email": "bob@example.com"},
    }
    return users.get(user_id)


# ✓ VALID: Proper handling of Optional return type
user_data = find_user(1)
if user_data is not None:
    name: str = user_data["name"]
    print(f"Found user: {name}")


def convert_value(value: Union[str, int]) -> str:
    """
    Convert a value to string format.

    Args:
        value: Either a string or integer

    Returns:
        String representation of the value
    """
    return str(value)


# ✓ VALID: Union types work correctly
result_str: str = convert_value("hello")
result_int: str = convert_value(123)


class DataProcessor:
    """Example class with proper type hints."""

    def __init__(self, name: str) -> None:
        """Initialize the processor."""
        self.name: str = name
        self.data: List[int] = []

    def add_data(self, value: int) -> None:
        """Add a value to the data list."""
        self.data.append(value)

    def get_total(self) -> int:
        """Get the sum of all data."""
        return sum(self.data)

    def get_info(self) -> str:
        """Get information about this processor."""
        return f"{self.name}: {len(self.data)} items"


# ✓ VALID: Proper class usage with type hints
processor: DataProcessor = DataProcessor("Counter")
processor.add_data(5)
processor.add_data(10)
total: int = processor.get_total()
info: str = processor.get_info()


# ============================================================================
# 6. ATTRIBUTE AND METHOD ERRORS
# ============================================================================

# ✗ LSP ERROR: Accessing non-existent attribute
processor.nonexistent_attribute  # Pyright: Cannot access member 'nonexistent_attribute'

# ✗ LSP ERROR: Calling non-existent method
processor.nonexistent_method()  # Pyright: Cannot access member 'nonexistent_method'

# ✗ LSP ERROR: Wrong type assignment to instance attribute
processor.name = 123  # Pyright: Expected 'str', got 'int'


# ============================================================================
# 7. GENERIC TYPE MISMATCHES
# ============================================================================

# ✓ VALID: Correct list type
numbers_list: List[int] = [1, 2, 3, 4, 5]

# ✗ LSP ERROR: Wrong item types in list literal
wrong_list: List[int] = [1, 2, "three", 4]  # Pyright: Expected 'int', got 'str'

# ✓ VALID: Correct dict type
user_dict: Dict[int, str] = {1: "Alice", 2: "Bob"}

# ✗ LSP ERROR: Wrong value type in dict literal
wrong_dict: Dict[int, str] = {1: "Alice", 2: 123}  # Pyright: Expected 'str', got 'int'


# ============================================================================
# 8. RETURN TYPE MISMATCHES
# ============================================================================

def get_name() -> str:
    """Should return a string."""
    return "Alice"


# ✓ VALID: Returns correct type
name = get_name()


def get_count() -> int:
    """Should return an integer."""
    return 42


# ✗ LSP ERROR: Function returns wrong type (implicit None)
def buggy_count() -> int:
    """This function has a type error - returns None implicitly."""
    if True:
        return 42
    # Missing else return - implicitly returns None
    # Pyright: Expression of type 'None' is incompatible with return type 'int'


# ✗ LSP ERROR: Function returns wrong type (explicit)
def buggy_name() -> str:
    """This function has a type error - returns int instead of str."""
    return 123  # Pyright: Expression of type 'int' is incompatible with return type 'str'


# ============================================================================
# 9. UNION TYPE USAGE
# ============================================================================

def process_input(value: Union[int, str]) -> None:
    """Process either an int or a string."""
    if isinstance(value, int):
        print(f"Integer: {value + 1}")
    else:
        print(f"String: {value.upper()}")


# ✓ VALID: Correct types
process_input(42)
process_input("hello")

# ✗ LSP ERROR: Wrong type - list not in Union
process_input([1, 2, 3])  # Pyright: Expected 'int | str', got 'list[int]'


# ============================================================================
# 10. SUMMARY OF WHAT PYRIGHT LSP DETECTS
# ============================================================================

"""
Summary of Pyright LSP Capabilities:

✓ DETECTS (Shows red squiggles and diagnostics):
  - Type mismatches in function arguments
  - Type mismatches in return values
  - Undefined variables and names
  - Missing imports
  - Non-existent module attributes
  - Non-existent class attributes and methods
  - Incorrect parameter counts
  - Wrong generic type parameters
  - Invalid type annotations
  - Missing required arguments
  - Extra unexpected arguments

✓ HELPS WITH (IDE Features):
  - Auto-completion with type information
  - Go to definition
  - Find all references
  - Hover type information
  - Quick fixes and suggestions
  - Rename refactoring

✓ SUPPORTS:
  - All standard Python type hints
  - Generic types (List, Dict, Set, etc.)
  - Optional and Union types
  - Type narrowing with isinstance checks
  - Custom class type checking
  - Type aliases
  - Protocol types
  - Literal types
"""
