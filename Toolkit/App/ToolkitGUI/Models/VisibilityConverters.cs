using System;
using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace ToolkitGUI.Models
{
    public sealed class InverseBooleanConverter : IValueConverter
    {
        public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
            => value is bool boolean && !boolean;

        public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
            => value is bool boolean && !boolean;
    }

    public sealed class InverseBooleanToVisibilityConverter : IValueConverter
    {
        public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
        {
            var isVisible = value is bool boolean && !boolean;
            return isVisible ? Visibility.Visible : Visibility.Collapsed;
        }

        public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
        {
            if (value is Visibility visibility)
            {
                return visibility != Visibility.Visible;
            }

            return true;
        }
    }
}
