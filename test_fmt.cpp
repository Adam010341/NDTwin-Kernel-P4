#include <fmt/core.h>
#include <iostream>
#include <stdexcept>
int main() {
    try {
        const char* p = nullptr;
        fmt::format("{}", p);
    } catch (const std::runtime_error& e) {
        std::cout << "runtime_error: " << e.what() << std::endl;
        return 0;
    } catch (const std::exception& e) {
        std::cout << "exception: " << e.what() << std::endl;
        return 0;
    } catch (...) {
        std::cout << "unknown" << std::endl;
    }
    return 0;
}
